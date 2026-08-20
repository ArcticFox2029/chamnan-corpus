/// Validação local do código BIC de um contentor (ISO 6346), o valor que vive em
/// `freight.containers.iso_code`. Serve para uma coisa só: recusar no telemóvel um código mal
/// lido pela câmara antes de gastar uma ida à rede e uma linha no outbox.
///
/// O container-registry valida na mesma — esta é a primeira barreira, não a única. A leitura
/// óptica confunde `0`/`O` e `1`/`I` com uma frequência que torna o dígito de controlo a defesa
/// mais útil que a app tem.
library;

/// Valor numérico de cada letra no cálculo ISO 6346. A tabela salta os múltiplos de 11 (11, 22,
/// 33), que é a razão de os valores não serem simplesmente 10..35 — quem a transcreve de cabeça
/// engana-se sempre no `L` e no `V`.
const Map<String, int> _letterValues = <String, int>{
  'A': 10, 'B': 12, 'C': 13, 'D': 14, 'E': 15, 'F': 16, 'G': 17, 'H': 18,
  'I': 19, 'J': 20, 'K': 21, 'L': 23, 'M': 24, 'N': 25, 'O': 26, 'P': 27,
  'Q': 28, 'R': 29, 'S': 30, 'T': 31, 'U': 32, 'V': 34, 'W': 35, 'X': 36,
  'Y': 37, 'Z': 38,
};

/// Identificador de categoria, a quarta letra. `U` é o contentor de carga normal; `J` é
/// equipamento destacável e `Z` é reboque ou chassis. Qualquer outra coisa não é um contentor.
const Set<String> _categoryIdentifiers = <String>{'U', 'J', 'Z'};

/// Motivo pelo qual um código foi recusado, para o ecrã dizer alguma coisa de útil em vez de
/// "código inválido".
enum BicRejection { length, ownerCode, category, serial, checkDigit }

class BicContainerCode {
  const BicContainerCode._(this.value);

  /// Normaliza e valida. Aceita espaços e minúsculas porque o condutor às vezes escreve o código
  /// à mão quando a placa está suja de sal e a câmara não a lê.
  static (BicContainerCode?, BicRejection?) tryParse(String raw) {
    final normalised = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

    if (normalised.length != 11) return (null, BicRejection.length);

    final owner = normalised.substring(0, 3);
    if (!owner.split('').every(_letterValues.containsKey)) {
      return (null, BicRejection.ownerCode);
    }
    if (!_categoryIdentifiers.contains(normalised[3])) {
      return (null, BicRejection.category);
    }

    final serial = normalised.substring(4, 10);
    if (!RegExp(r'^\d{6}$').hasMatch(serial)) return (null, BicRejection.serial);

    final declared = int.tryParse(normalised[10]);
    if (declared == null) return (null, BicRejection.checkDigit);
    if (declared != checkDigitFor(normalised.substring(0, 10))) {
      return (null, BicRejection.checkDigit);
    }

    return (BicContainerCode._(normalised), null);
  }

  /// Dígito de controlo dos primeiros dez caracteres: soma ponderada por potências de dois,
  /// resto da divisão por 11, e o 10 colapsa em 0.
  static int checkDigitFor(String firstTen) {
    var sum = 0;
    for (var i = 0; i < 10; i++) {
      final ch = firstTen[i];
      final value = _letterValues[ch] ?? int.parse(ch);
      sum += value * (1 << i);
    }
    return (sum % 11) % 10;
  }

  /// Os onze caracteres, tal como vão para `freight.containers.iso_code`.
  final String value;

  /// Prefixo do proprietário, as três primeiras letras. Não o usamos para nada de negócio — o
  /// dono real do contentor é `freight.containers.owner_carrier_id`, que aponta para
  /// `fleet.carriers` e pode não ter nada a ver com o prefixo estampado na caixa.
  String get ownerCode => value.substring(0, 3);

  String get serialNumber => value.substring(4, 10);

  /// Formatação legível para o ecrã de confirmação: `MSCU 394857 1`.
  String get pretty => '${value.substring(0, 4)} ${value.substring(4, 10)} ${value[10]}';

  @override
  String toString() => value;
}

/// Descodifica `freight.containers.iso_size_type` (por exemplo `45R1`) apenas o suficiente para
/// o ecrã dizer "40 pés, reefer". A tabela completa vive no container-registry; aqui só se lê o
/// primeiro carácter, que é o comprimento, e o terceiro, que é o tipo.
String describeIsoSizeType(String isoSizeType) {
  if (isoSizeType.length != 4) return isoSizeType;

  final length = switch (isoSizeType[0]) {
    '2' => '20 pés',
    '4' => '40 pés',
    'L' => '45 pés',
    _ => 'comprimento ${isoSizeType[0]}',
  };
  final type = switch (isoSizeType[2]) {
    'G' => 'carga geral',
    'R' => 'reefer',
    'T' => 'cisterna',
    'U' => 'topo aberto',
    'P' => 'plataforma',
    _ => 'tipo ${isoSizeType[2]}',
  };
  return '$length · $type';
}
