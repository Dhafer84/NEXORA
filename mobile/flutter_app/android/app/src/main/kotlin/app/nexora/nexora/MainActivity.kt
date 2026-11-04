package app.nexora.nexora

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Local file organisation through the Storage Access Framework: NEXORA only sees
 * the folder or the files the user picked, with no broad storage permission
 * (no MANAGE_EXTERNAL_STORAGE). Every move or rename is requested one by one by
 * the Dart side after an explicit validation. Nothing is ever deleted, copied or
 * overwritten here: a move the provider refuses is reported, never replaced by a
 * copy followed by a deletion.
 *
 * Also saves or shares an Activité export the user previewed.
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pendingPick: MethodChannel.Result? = null
    private var pendingFiles: Pair<MethodChannel.Result, Uri?>? = null
    private var pendingSave: Pair<MethodChannel.Result, String>? = null
    private var voice: VoiceBridge? = null
    private var bubble: BubbleBridge? = null
    private var session: MethodChannel? = null
    private var health: HealthBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "app.nexora/files").setMethodCallHandler(::handle)
        voice = VoiceBridge(this, messenger)
        bubble = BubbleBridge(this, messenger, inBubble = false)
        session = SessionHub.attach(messenger, "app")
        health = HealthBridge(this, messenger)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        bubble?.onNewIntent(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (health?.onActivityResult(requestCode) == true) return
        if (voice?.onPermissionResult(requestCode, grantResults) != true) {
            bubble?.onPermissionResult(requestCode)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        voice?.dispose()
        bubble?.dispose()
        session?.let(SessionHub::detach)
        health?.dispose()
        health = null
        voice = null
        bubble = null
        session = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "checkAccess" -> background(result) { checkAccess(Uri.parse(call.arg("tree"))) }
            "pickFiles" -> pickFiles(result, call.argument<String>("tree")?.let(Uri::parse))
            "moveFile" -> background(result) {
                moveFile(Uri.parse(call.arg("uri")), Uri.parse(call.arg("tree")), call.arg("targetId"))
            }
            "renameFile" -> background(result) {
                renameFile(Uri.parse(call.arg("uri")), Uri.parse(call.arg("tree")), call.arg("name"))
            }
            "saveExport" -> saveExport(result, call.arg("name"), call.arg("mime"), call.arg("content"))
            "shareExport" -> background(result) {
                shareExport(call.arg("name"), call.arg("mime"), call.arg("content"))
            }
            "purgeExports" -> background(result) { purgeExports() }
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
        // Android 11+ refuses the root of Download (and of the storage) as a
        // tree: the picker opens there so that a sub-folder can be chosen or
        // created, e.g. Download/NEXORA. That restriction is never bypassed.
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, DOWNLOAD)
        startActivityForResult(intent, PICK_FOLDER)
    }

    /** `ok`, or `revoked` when the folder's access was withdrawn or it vanished. */
    private fun checkAccess(tree: Uri): String {
        val granted = contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }
        if (!granted) return "revoked"
        return try {
            children(tree, rootId(tree))
            "ok"
        } catch (error: SecurityException) {
            "revoked"
        } catch (error: Exception) {
            "revoked"
        }
    }

    // ----- Individual files ----------------------------------------------------

    /**
     * Several documents, the Download root included (ACTION_OPEN_DOCUMENT).
     * Each one says whether it lies inside the authorised [tree].
     */
    private fun pickFiles(result: MethodChannel.Result, tree: Uri?) {
        if (pendingFiles != null) {
            result.error("busy", "Sélection déjà en cours", null)
            return
        }
        pendingFiles = result to tree
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, DOWNLOAD)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        startActivityForResult(intent, PICK_FILES)
    }

    private fun picked(data: Intent?): List<Uri> {
        val clip = data?.clipData
        if (clip != null) return (0 until clip.itemCount).map { clip.getItemAt(it).uri }
        return listOfNotNull(data?.data)
    }

    /**
     * Document id of a picked file inside the authorised [tree], or null. Only
     * there can NEXORA see the neighbouring names and check a conflict: the
     * picker's own grant covers the file alone, not its new address after a
     * rename nor its folder.
     */
    private fun inTree(uri: Uri, tree: Uri?): String? {
        if (tree == null || uri.authority != tree.authority) return null
        val id = try {
            DocumentsContract.getDocumentId(uri)
        } catch (error: IllegalArgumentException) {
            return null
        }
        return id.takeIf { it.startsWith(rootId(tree) + "/") }
    }

    /** What the provider says about one picked document, flags included. */
    private fun describe(uri: Uri, tree: Uri?): Map<String, Any?> {
        val columns = arrayOf(
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )
        contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val flags = if (cursor.isNull(4)) 0 else cursor.getInt(4)
                return mapOf(
                    "uri" to uri.toString(),
                    "authority" to uri.authority,
                    "inFolder" to (inTree(uri, tree) != null),
                    "name" to cursor.getString(0),
                    "mime" to cursor.getString(1),
                    "size" to if (cursor.isNull(2)) null else cursor.getLong(2),
                    "modified" to if (cursor.isNull(3)) null else cursor.getLong(3),
                    "canMove" to (flags and Document.FLAG_SUPPORTS_MOVE != 0),
                    "canRename" to (flags and Document.FLAG_SUPPORTS_RENAME != 0),
                )
            }
        }
        throw FileOperationException("not_found", "Fichier introuvable")
    }

    /**
     * Moves one picked document into the sub-folder [targetId] of [tree]:
     * only for a document inside that folder, through its access (name
     * conflicts checked). Anything else is reported as unsupported.
     */
    private fun moveFile(uri: Uri, tree: Uri, targetId: String): String {
        val id = inTree(uri, tree)
            ?: throw FileOperationException("move_unsupported", "Fichier hors du dossier autorisé")
        return move(tree, id, targetId, parentOf(id))
    }

    /** Renames one picked document inside [tree], neighbours checked first. */
    private fun renameFile(uri: Uri, tree: Uri, name: String): String {
        val id = inTree(uri, tree)
            ?: throw FileOperationException("rename_unsupported", "Fichier hors du dossier autorisé")
        return rename(tree, id, name, parentOf(id))
    }

    /** `primary:Download/A/x.pdf` → `primary:Download/A`. */
    private fun parentOf(id: String): String = id.substringBeforeLast('/')

    /**
     * Some providers add « (1) » instead of refusing a taken name: the rename
     * is undone and reported as a conflict, so nothing is silently renamed.
     */
    private fun undoUniqueName(renamed: Uri, wanted: String, original: String) {
        if (displayName(renamed) == wanted) return
        try {
            DocumentsContract.renameDocument(contentResolver, renamed, original)
        } catch (error: Exception) {
            // Left under the provider's name; reported below.
        }
        throw FileOperationException("name_taken", "Un fichier du même nom existe déjà")
    }

    // ----- Activité export -------------------------------------------------------

    /** The user picks where to save; returns the saved name, or null if cancelled. */
    private fun saveExport(result: MethodChannel.Result, name: String, mime: String, content: String) {
        if (pendingSave != null) {
            result.error("busy", "Enregistrement déjà en cours", null)
            return
        }
        pendingSave = result to content
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mime)
            .putExtra(Intent.EXTRA_TITLE, name)
        startActivityForResult(intent, SAVE_EXPORT)
    }

    private fun exportsDir() = File(cacheDir, "exports")

    /** Temporary copy in cache/exports (no backup), opened by the app the user chooses. */
    private fun shareExport(name: String, mime: String, content: String): Boolean {
        checkName(name)
        purgeExports()
        val dir = exportsDir().apply { mkdirs() }
        val file = File(dir, name).apply { writeText(content) }
        val uri = FileProvider.getUriForFile(this, "$packageName.exports", file)
        val send = Intent(Intent.ACTION_SEND)
            .setType(mime)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        main.post {
            startActivity(Intent.createChooser(send, "Partager l’export").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
        }
        return true
    }

    /** Removes earlier shared exports. */
    private fun purgeExports(): Int {
        val files = exportsDir().listFiles() ?: return 0
        return files.count { it.delete() }
    }

    @Deprecated("FlutterActivity is not a ComponentActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (health?.onActivityResult(requestCode) == true) return
        when (requestCode) {
            PICK_FILES -> {
                val (result, tree) = pendingFiles ?: return
                pendingFiles = null
                if (resultCode != Activity.RESULT_OK) {
                    result.success(null)
                    return
                }
                background(result) { picked(data).map { describe(it, tree) } }
                return
            }
            SAVE_EXPORT -> {
                val (result, content) = pendingSave ?: return
                pendingSave = null
                val target = data?.data
                if (resultCode != Activity.RESULT_OK || target == null) {
                    result.success(null)
                    return
                }
                background(result) {
                    contentResolver.openOutputStream(target, "wt")?.use { it.write(content.toByteArray()) }
                        ?: throw FileOperationException("write_failed", "Écriture impossible")
                    displayName(target) ?: "export"
                }
                return
            }
            PICK_FOLDER -> Unit
            else -> return
        }
        val result = pendingPick ?: return
        pendingPick = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                tree,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (error: SecurityException) {
            result.error("not_persistable", "Le fournisseur n’accorde pas un accès durable à ce dossier", null)
            return
        }
        // Rights really obtained: reading and writing, kept after a restart.
        val rights = contentResolver.persistedUriPermissions.firstOrNull { it.uri == tree }
        if (rights == null || !rights.isReadPermission || !rights.isWritePermission) {
            result.error("no_write", "Accès en écriture non accordé à ce dossier", null)
            return
        }
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

    private fun move(tree: Uri, documentId: String, targetId: String, parentId: String = rootId(tree)): String {
        val source = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val name = displayName(source) ?: throw FileOperationException("not_found", "Fichier introuvable")
        // Never overwrite: the Dart side proposes a free name first.
        if (children(tree, targetId).any { it["name"] == name }) {
            throw FileOperationException("name_taken", "Un fichier du même nom existe déjà")
        }
        val moved = try {
            DocumentsContract.moveDocument(
                contentResolver,
                source,
                DocumentsContract.buildDocumentUriUsingTree(tree, parentId),
                DocumentsContract.buildDocumentUriUsingTree(tree, targetId),
            )
        } catch (error: UnsupportedOperationException) {
            null
        } catch (error: IllegalStateException) {
            null
        } ?: throw FileOperationException("move_unsupported", "Déplacement non pris en charge")
        return DocumentsContract.getDocumentId(moved)
    }

    private fun rename(tree: Uri, documentId: String, name: String, parentId: String = rootId(tree)): String {
        checkName(name)
        if (children(tree, parentId).any { it["name"] == name }) {
            throw FileOperationException("name_taken", "Un fichier du même nom existe déjà")
        }
        val source = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val original = displayName(source) ?: throw FileOperationException("not_found", "Fichier introuvable")
        val renamed = DocumentsContract.renameDocument(contentResolver, source, name)
            ?: throw FileOperationException("rename_unsupported", "Renommage non pris en charge")
        undoUniqueName(renamed, name, original)
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
        private const val PICK_FILES = 4202
        private const val SAVE_EXPORT = 4203

        /** Where both pickers open: the Download folder of the main storage. */
        private val DOWNLOAD: Uri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:Download",
        )
    }
}
