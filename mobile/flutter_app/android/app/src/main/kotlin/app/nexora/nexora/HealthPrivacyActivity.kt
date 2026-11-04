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
                Données de santé dans NEXORA

                NEXORA lit dans Health Connect, seulement après votre autorisation et catégorie par catégorie : les pas, le sommeil, la fréquence cardiaque, les entraînements et leur distance.

                Ces données servent à l’onglet Activité et au diagnostic : totaux par jour, courbes, date, fuseau horaire et application d’origine des entrées (par exemple Health Sync).

                Elles restent sur ce téléphone, dans une copie chiffrée des dernières lectures que vous pouvez effacer depuis l’onglet Activité. NEXORA ne les écrit pas dans ses journaux et ne les sauvegarde pas ailleurs.

                Rien n’est envoyé au serveur NEXORA ni à un fournisseur d’IA, sauf si vous demandez « Analyser avec l’IA » : NEXORA vous montre alors le résumé chiffré exact et son destinataire, et n’envoie ce seul résumé qu’après votre confirmation. Un export CSV ou JSON n’est enregistré ou partagé que lorsque vous le choisissez.

                Vous pouvez retirer ces autorisations à tout moment dans Health Connect.
            """.trimIndent()
        }
        setContentView(ScrollView(this).apply { addView(text) })
    }
}
