// Ecrã de entrada: troca as credenciais do condutor por um par de tokens no identity-service e
// confirma que a conta tem mesmo o papel `driver` antes de deixar chegar à lista de entregas.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/driver_app.dart';
import '../../assignments/presentation/assignment_list_screen.dart';
import '../data/identity_repository.dart';

/// Ecrã de entrada. Existe para um caso só — o condutor que acabou de receber o telemóvel do
/// turno — e por isso é deliberadamente pobre: e-mail, palavra-passe e o segundo fator quando o
/// identity-service o pedir. Não há registo, não há recuperação de palavra-passe, não há troca de
/// inquilino; essas coisas fazem-se na consola web de `web/`.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _mfa = TextEditingController();

  bool _busy = false;
  bool _mfaVisible = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _mfa.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _message = null;
    });

    final identity = ref.read(serviceLocatorProvider).get<IdentityRepository>();
    final outcome = await identity.signIn(
      email: _email.text.trim(),
      password: _password.text,
      mfaCode: _mfaVisible ? _mfa.text.trim() : null,
    );

    if (!mounted) return;

    switch (outcome) {
      case SignInOutcome.granted:
        // Confirmamos o papel antes de deixar entrar. Um utilizador sem `driver` não tem linha em
        // `fleet.drivers` e nunca vai aparecer em `GET /v1/assignments`.
        final roles = await identity.effectiveRoleCodes();
        if (!mounted) return;
        if (!roles.contains('driver')) {
          setState(() {
            _busy = false;
            _message = 'Esta conta não tem o papel "driver". Use a consola web.';
          });
          return;
        }
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const AssignmentListScreen()),
        );
      case SignInOutcome.mfaRequired:
        setState(() {
          _busy = false;
          _mfaVisible = true;
          _message = 'Introduza o código da aplicação de autenticação.';
        });
      case SignInOutcome.offline:
        setState(() {
          _busy = false;
          _message = 'Sem rede. A entrada precisa do identity-service pelo menos uma vez.';
        });
      case SignInOutcome.rejected:
        setState(() {
          _busy = false;
          _message = 'Credenciais recusadas.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            children: <Widget>[
              const SizedBox(height: 48),
              Text('ORBITALFREIGHT', style: Theme.of(context).textTheme.headlineSmall),
              Text('Condutor', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 32),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'E-mail'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Palavra-passe'),
              ),
              if (_mfaVisible) ...<Widget>[
                const SizedBox(height: 16),
                TextField(
                  controller: _mfa,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Código MFA'),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? 'A entrar…' : 'Entrar'),
              ),
              if (_message != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
