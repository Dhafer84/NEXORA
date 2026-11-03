package app.nexora.nexora

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView

/**
 * Shown by Health Connect from its permission screens ("Pourquoi cette
 * application demande l'accès ?"): how NEXORA uses the health data it reads.
 */
class HealthPrivacyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "NEXORA — données de santé"
        val padding = (24 * resources.displayMetrics.density).toInt()
        val text = TextView(this).apply {
            setPadding(padding, padding, padding, padding)
            textSize = 16f
            text = """
                Diagnostic santé de NEXORA (prototype)

                NEXORA lit dans Health Connect, seulement après votre autorisation et catégorie par catégorie : les pas, le sommeil, la fréquence cardiaque et les entraînements.

                Ces données servent uniquement à l’écran de diagnostic de ce téléphone : total d’une journée, date, fuseau horaire et application d’origine des entrées (par exemple Health Sync).

                Elles restent sur ce téléphone. NEXORA ne les enregistre pas, ne les écrit pas dans ses journaux et ne les envoie ni à son serveur ni à un fournisseur d’IA.

                Vous pouvez retirer ces autorisations à tout moment dans Health Connect.
            """.trimIndent()
        }
        setContentView(ScrollView(this).apply { addView(text) })
    }
}
