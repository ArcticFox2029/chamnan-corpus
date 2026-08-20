// Copyright (c) 2026 ORBITALFREIGHT Holdings B.V.
// Uso interno. Distribuição sujeita ao acordo de licença do repositório.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/driver_environment.dart';
import '../core/network/of_session.dart';
import '../features/assignments/presentation/assignment_list_screen.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import 'service_locator.dart';

/// Widget de topo: escolhe entre o ecrã de entrada e a lista de atribuições, e disponibiliza o
/// `ServiceLocator` a toda a árvore através de um `Provider` do Riverpod. Não tem lógica de
/// negócio nenhuma — tudo o que decide alguma coisa vive nos repositórios de `features/`.
///
/// O tema é propositadamente de alto contraste e com alvos de toque grandes: isto é usado com
/// luvas, dentro de uma cabina, muitas vezes com sol direto no ecrã.
class DriverApp extends StatelessWidget {
  const DriverApp({required this.locator, super.key});

  final ServiceLocator locator;

  @override
  Widget build(BuildContext context) {
    final environment = locator.get<DriverEnvironment>();
    final session = locator.get<OfSession>();

    return ProviderScope(
      overrides: <Override>[
        serviceLocatorProvider.overrideWithValue(locator),
      ],
      child: MaterialApp(
        title: 'ORBITALFREIGHT Driver',
        debugShowCheckedModeBanner: !environment.isProduction,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        // O condutor escolhe; a maior parte anda em modo escuro porque conduz de noite.
        themeMode: ThemeMode.system,
        home: session.isAuthenticated
            ? const AssignmentListScreen()
            : const SignInScreen(),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0B5C8A),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 56 dp de altura mínima: um botão de 40 dp é impossível de acertar com luvas de trabalho
      // num camião a abanar. Medido com condutores em Rotterdam, não inventado.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
    );
  }
}

/// Acesso ao grafo de dependências a partir de qualquer widget. É sempre substituído em
/// `DriverApp`; o `UnimplementedError` só dispara se alguém montar um ecrã fora da app.
final Provider<ServiceLocator> serviceLocatorProvider = Provider<ServiceLocator>(
  (ref) => throw UnimplementedError('serviceLocatorProvider tem de ser substituído em DriverApp'),
);
