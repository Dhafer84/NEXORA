package app.nexora.nexora

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Local file organisation through the Storage Access Framework: NEXORA only sees
 * the folder the user picked, with no broad storage permission. Every move or
 * rename is requested one by one by the Dart side after an explicit validation.
 * Nothing is ever deleted, copied or overwritten here.
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pendingPick: MethodChannel.Result? = null
    private var voice: VoiceBridge? = null
    private var bubble: BubbleBridge? = null
    private var session: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "app.nexora/files").setMethodCallHandler(::handle)
        voice = VoiceBridge(this, messenger)
        bubble = BubbleBridge(this, messenger, inBubble = false)
        session = SessionHub.attach(messenger, "app")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        bubble?.onNewIntent(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (voice?.onPermissionResult(requestCode, grantResults) != true) {
            bubble?.onPermissionResult(requestCode)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        voice?.dispose()
        bubble?.dispose()
        session?.let(SessionHub::detach)
        voice = null
        bubble = null
        session = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "listFiles" -> background(result) { listFiles(Uri.parse(call.arg("tree"))) }
            "ensureFolder" -> background(result) {
                ensureFolder(Uri.parse(call.arg("tree")), call.arg("name"))
            }
            "move" -> background(result) {
                move(Uri.parse(call.arg("tree")), call.arg("documentId"), call.arg("targetId"))
            }
            "rename" -> background(result) {
                rename(Uri.parse(call.arg("tree")), call.arg("documentId"), call.arg("name"))
            }
            "release" -> background(result) {
                contentResolver.releasePersistableUriPermission(
                    Uri.parse(call.arg("tree")),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun <T> MethodCall.arg(name: String): T =
        argument<T>(name) ?: throw IllegalArgumentException("argument manquant : $name")

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (error: FileOperationException) {
                main.post { result.error(error.code, error.message, null) }
            } catch (error: SecurityException) {
                main.post { result.error("access_denied", "Accès au dossier retiré", null) }
            } catch (error: Exception) {
                main.post { result.error("failed", error.javaClass.simpleName, null) }
            }
        }
    }

    // ----- Folder selection ----------------------------------------------------

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "Sélection déjà en cours", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        startActivityForResult(intent, PICK_FOLDER)
    }

    @Deprecated("FlutterActivity is not a ComponentActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FOLDER) return
        val result = pendingPick ?: return
        pendingPick = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return
        }
        contentResolver.takePersistableUriPermission(
            tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        background(result) {
            val root = DocumentsContract.buildDocumentUriUsingTree(
                tree,
                DocumentsContract.getTreeDocumentId(tree),
            )
            mapOf("tree" to tree.toString(), "name" to (displayName(root) ?: "Dossier"))
        }
    }

    // ----- Documents -------------------------------------------------------------

    private fun rootId(tree: Uri): String = DocumentsContract.getTreeDocumentId(tree)

    private fun displayName(document: Uri): String? =
        contentResolver.query(document, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }

    private fun children(tree: Uri, parentId: String): List<Map<String, Any?>> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )
        val found = mutableListOf<Map<String, Any?>>()
        contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val flags = cursor.getInt(5)
                found += mapOf(
                    "id" to cursor.getString(0),
                    "name" to cursor.getString(1),
                    "mime" to cursor.getString(2),
                    "size" to if (cursor.isNull(3)) null else cursor.getLong(3),
                    "modified" to if (cursor.isNull(4)) null else cursor.getLong(4),
                    "canMove" to (flags and Document.FLAG_SUPPORTS_MOVE != 0),
                    "canRename" to (flags and Document.FLAG_SUPPORTS_RENAME != 0),
                )
            }
        }
        return found
    }

    /** Files and folders directly in the picked folder (not recursive). */
    private fun listFiles(tree: Uri): List<Map<String, Any?>> = children(tree, rootId(tree))

    /** Existing sub-folder with this name, or a new one. Returns its document id. */
    private fun ensureFolder(tree: Uri, name: String): String {
        checkName(name)
        val root = rootId(tree)
        children(tree, root)
            .firstOrNull { it["name"] == name && it["mime"] == Document.MIME_TYPE_DIR }
            ?.let { return it["id"] as String }
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, root)
        val created = DocumentsContract.createDocument(
            contentResolver, parent, Document.MIME_TYPE_DIR, name,
        ) ?: throw FileOperationException("create_failed", "Dossier non créé")
        return DocumentsContract.getDocumentId(created)
    }

    private fun move(tree: Uri, documentId: String, targetId: String): String {
        val root = rootId(tree)
        val source = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val name = displayName(source) ?: throw FileOperationException("not_found", "Fichier introuvable")
        // Never overwrite: the Dart side proposes a free name first.
        if (children(tree, targetId).any { it["name"] == name }) {
            throw FileOperationException("name_taken", "Un fichier du même nom existe déjà")
        }
        val moved = DocumentsContract.moveDocument(
            contentResolver,
            source,
            DocumentsContract.buildDocumentUriUsingTree(tree, root),
            DocumentsContract.buildDocumentUriUsingTree(tree, targetId),
        ) ?: throw FileOperationException("move_unsupported", "Déplacement non pris en charge")
        return DocumentsContract.getDocumentId(moved)
    }

    private fun rename(tree: Uri, documentId: String, name: String): String {
        checkName(name)
        if (children(tree, rootId(tree)).any { it["name"] == name }) {
            throw FileOperationException("name_taken", "Un fichier du même nom existe déjà")
        }
        val source = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val renamed = DocumentsContract.renameDocument(contentResolver, source, name)
            ?: throw FileOperationException("rename_unsupported", "Renommage non pris en charge")
        return DocumentsContract.getDocumentId(renamed)
    }

    private fun checkName(name: String) {
        if (name.isBlank() || name.length > 120 || name.contains('/') || name.startsWith(".")) {
            throw FileOperationException("invalid_name", "Nom refusé")
        }
    }

    private class FileOperationException(val code: String, message: String) : Exception(message)

    companion object {
        private const val PICK_FOLDER = 4201
    }
}
