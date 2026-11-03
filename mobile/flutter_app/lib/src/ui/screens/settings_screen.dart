import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../state/app_state.dart';
import '../widgets/states.dart';

/// Backend address and personal key. The stored key is never displayed again.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.firstRun = false});

  final bool firstRun;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _obscure = true;
  bool _busy = false;
  ConnectionReport? _report;
  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialised) {
      _url.text = AppScope.read(context).baseUrl ?? '';
      _initialised = true;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    final state = AppScope.read(context);
    final typed = _key.text.trim();
    // The stored key is only ever tested against its own address.
    final key = typed.isNotEmpty ? typed : await state.storedKeyFor(_url.text);
    if (key == null) {
      setState(
        () => _report = ConnectionReport.failure(
          state.hasKey
              ? AppState.newAddressNeedsKey
              : 'Saisissez la clé personnelle.',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _report = null;
    });
    final report = await state.testConnection(_url.text, key);
    if (mounted) {
      setState(() {
        _busy = false;
        _report = report;
      });
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final state = AppScope.read(context);
    if (!state.hasKey && _key.text.trim().isEmpty) {
      setState(
        () => _report = const ConnectionReport.failure(
          'Saisissez la clé personnelle.',
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final problem = await state.save(_url.text, _key.text);
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _busy = false;
        _report = ConnectionReport.failure(problem);
      });
      return;
    }
    _key.clear();
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Réglages enregistrés.')));
  }

  Future<void> _deleteKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer la clé ?'),
        content: const Text(
          'La clé sera effacée de ce téléphone. Il faudra la saisir de nouveau '
          'pour accéder au serveur. La clé reste valable côté serveur.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final state = AppScope.read(context);
    var deleted = true;
    try {
      await state.deleteKey();
    } on Object {
      deleted = false;
    }
    if (!mounted) return;
    setState(() => _report = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted
              ? 'Clé supprimée de ce téléphone.'
              : 'Suppression impossible : la clé est toujours enregistrée. Réessayez.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.firstRun ? 'Bienvenue dans NEXORA' : 'Réglages'),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.vpn_lock,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Le serveur NEXORA est privé : activez Tailscale sur ce téléphone '
                          'avant de vous connecter. Sans Tailscale, le serveur est injoignable.',
                          style: TextStyle(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Adresse HTTPS du serveur',
                  hintText: 'https://mon-serveur.tailnet.ts.net:8101',
                  errorMaxLines: 3,
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
                validator: (value) => checkBaseUrl(value ?? ''),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _key,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: state.hasKey
                      ? 'Nouvelle clé personnelle (facultatif)'
                      : 'Clé personnelle',
                  helperMaxLines: 3,
                  helperText: state.hasKey
                      ? 'Une clé est enregistrée pour cette adresse. Laissez vide '
                            'pour la conserver ; une nouvelle adresse exige sa clé.'
                      : 'La clé est conservée dans le stockage sécurisé Android.',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    tooltip: _obscure
                        ? 'Afficher la saisie'
                        : 'Masquer la saisie',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_busy) const LinearProgressIndicator(),
              if (_report != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: NoticeBar(
                    tone: _report!.ok ? 'ok' : 'error',
                    message: _report!.message,
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Tester la connexion'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Enregistrer'),
                  ),
                ],
              ),
              if (state.hasKey) ...[
                const SizedBox(height: 32),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Supprimer la clé de ce téléphone'),
                  subtitle: const Text(
                    'Pour changer de téléphone ou révoquer l’accès local.',
                  ),
                  onTap: _busy ? null : _deleteKey,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'La clé personnelle n’est jamais affichée ni envoyée ailleurs qu’au serveur '
                'indiqué, en HTTPS avec vérification du certificat. Aucune clé de fournisseur '
                'IA n’est stockée dans l’application.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
