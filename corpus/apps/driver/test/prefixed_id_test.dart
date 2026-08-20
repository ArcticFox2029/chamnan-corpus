/// Testes dos identificadores com prefixo de §0.1. A regra que estes testes protegem é a de que o
/// prefixo faz parte do valor e nunca é retirado em trânsito: houve uma versão do cliente iOS que
/// enviava o ULID sem o `scn_` e o container-registry rejeitava a leitura inteira.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitalfreight_driver/core/ids/prefixed_id.dart';

void main() {
  group('parse', () {
    const raw = 'shp_01J8ZK4T9QW3RM7XN2VB6HD5PC';

    test('aceita o prefixo correto e mantém o valor completo', () {
      final id = PrefixedId.parse(IdPrefix.shipment, raw);
      expect(id.value, raw);
      expect(id.toString(), raw);
      expect(id.body.length, 26);
    });

    test('recusa o prefixo trocado', () {
      // O caso real: um `shp_` a entrar numa assinatura que espera um `cnt_`. Sem esta
      // verificação, a leitura ia parar ao contentor errado e ninguém dava por isso.
      expect(
        () => PrefixedId.parse(IdPrefix.container, raw),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa um corpo com letras fora do alfabeto de Crockford', () {
      // `I`, `L`, `O` e `U` não existem no alfabeto, precisamente para não se confundirem com
      // `1` e `0` quando alguém lê um identificador em voz alta ao telefone.
      expect(
        () => PrefixedId.parse(IdPrefix.shipment, 'shp_01J8ZK4T9QW3RM7XN2VB6HD5PI'),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa um corpo com o comprimento errado', () {
      expect(
        () => PrefixedId.parse(IdPrefix.scan, 'scn_01J8ZK4T9'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('generate', () {
    test('produz um identificador que o parse aceita', () {
      final id = PrefixedId.generate(IdPrefix.scan, random: Random(7));
      expect(id.value.startsWith('scn_'), isTrue);
      expect(PrefixedId.parse(IdPrefix.scan, id.value), id);
    });

    test('codifica o instante nos primeiros 48 bits', () {
      final at = DateTime.utc(2026, 3, 14, 9, 21, 44, 118);
      final id = PrefixedId.generate(IdPrefix.event, at: at, random: Random(1));
      expect(id.createdAt, at);
    });

    test('ordena lexicograficamente pela ordem de criação', () {
      // É esta propriedade que o outbox local usa para enviar as escritas pela ordem em que o
      // condutor as fez, sem precisar de uma coluna de sequência.
      final first = PrefixedId.generate(
        IdPrefix.event,
        at: DateTime.utc(2026, 3, 14, 9, 0),
        random: Random(1),
      );
      final second = PrefixedId.generate(
        IdPrefix.event,
        at: DateTime.utc(2026, 3, 14, 9, 0, 1),
        random: Random(1),
      );
      expect(first.value.compareTo(second.value) < 0, isTrue);
    });
  });

  group('igualdade', () {
    test('dois identificadores com o mesmo valor são iguais', () {
      const raw = 'drv_01J8ZK4T9QW3RM7XN2VB6HD5PC';
      expect(
        PrefixedId.parse(IdPrefix.driver, raw),
        PrefixedId.parse(IdPrefix.driver, raw),
      );
    });
  });
}
