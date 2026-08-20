/// Testes do validador ISO 6346. Existem por causa de um incidente concreto: a versão 3.4 aceitava
/// qualquer coisa com onze caracteres e criou 60 leituras contra contentores que não existiam em
/// `freight.containers`, todas rejeitadas pelo container-registry horas depois, quando o condutor
/// já tinha saído do terminal.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitalfreight_driver/features/scanning/domain/bic_container_code.dart';

void main() {
  group('dígito de controlo', () {
    test('aceita códigos válidos', () {
      // CSQU3054383 é o exemplo canónico da própria norma.
      for (final raw in <String>[
        'CSQU3054383',
        'MSCU3948578',
        'TGHU7564186',
        'HLXU1234561',
      ]) {
        final (code, rejection) = BicContainerCode.tryParse(raw);
        expect(rejection, isNull, reason: raw);
        expect(code!.value, raw);
      }
    });

    test('recusa o dígito de controlo errado', () {
      final (code, rejection) = BicContainerCode.tryParse('CSQU3054384');
      expect(code, isNull);
      expect(rejection, BicRejection.checkDigit);
    });

    test('calcula o dígito a partir dos primeiros dez caracteres', () {
      expect(BicContainerCode.checkDigitFor('CSQU305438'), 3);
      expect(BicContainerCode.checkDigitFor('TGHU756418'), 6);
    });
  });

  group('normalização', () {
    test('aceita minúsculas e espaços da introdução manual', () {
      final (code, rejection) = BicContainerCode.tryParse('csqu 305438 3');
      expect(rejection, isNull);
      expect(code!.value, 'CSQU3054383');
      expect(code.pretty, 'CSQU 305438 3');
    });

    test('separa o motivo da recusa', () {
      expect(BicContainerCode.tryParse('CSQU30543').$2, BicRejection.length);
      expect(BicContainerCode.tryParse('CS1U3054383').$2, BicRejection.ownerCode);
      // A quarta letra tem de ser U, J ou Z; um `X` é um erro de leitura típico do `U`.
      expect(BicContainerCode.tryParse('CSQX3054383').$2, BicRejection.category);
      expect(BicContainerCode.tryParse('CSQU30543X3').$2, BicRejection.serial);
    });
  });

  group('iso_size_type', () {
    test('descreve os tipos que aparecem na app', () {
      expect(describeIsoSizeType('45R1'), '40 pés · reefer');
      expect(describeIsoSizeType('22G1'), '20 pés · carga geral');
      // Um valor que não conhecemos passa como está — o ecrã mostra o código cru em vez de
      // mentir sobre o que a caixa é.
      expect(describeIsoSizeType('99X9'), 'comprimento 9 · tipo X');
    });
  });
}
