/// Identificadores com prefixo (§0.1 do SPEC) tratados como um tipo e não como `String` solta.
/// O objetivo é impedir a troca silenciosa entre um `shp_` e um `cnt_` quando ambos passam pela
/// mesma assinatura de função — já aconteceu no cliente `apps/driver-ios/` e custou uma leitura
/// atribuída ao contentor errado.
///
/// A app também gera identificadores localmente: uma leitura feita sem rede precisa de um `scn_`
/// antes de chegar ao container-registry, e é esse valor que segue no corpo do pedido.
library;

import 'dart:math';

/// Prefixos que a app do condutor manipula. A tabela completa de §0.1 tem 32 entradas; aqui
/// estão apenas os que atravessam este cliente.
enum IdPrefix {
  tenant('tnt_'),
  user('usr_'),
  driver('drv_'),
  vehicle('veh_'),
  assignment('asg_'),
  shipment('shp_'),
  container('cnt_'),
  scan('scn_'),
  facility('fac_'),
  route('rte_'),
  leg('leg_'),
  document('doc_'),
  geofence('gfn_'),
  event('evt_');

  const IdPrefix(this.value);

  /// O prefixo faz parte do valor e nunca é retirado em trânsito (§0.1).
  final String value;
}

/// Alfabeto de Crockford usado pelo ULID. Sem `I`, `L`, `O` e `U`.
const String _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Um identificador validado. `toString()` devolve o valor completo, com prefixo, pronto a
/// serializar.
class PrefixedId {
  const PrefixedId._(this.prefix, this.value);

  /// Valida um valor vindo do servidor. Lança se o prefixo não for o esperado — é preferível
  /// falhar na desserialização a propagar um identificador trocado para dentro do SQLite local.
  factory PrefixedId.parse(IdPrefix prefix, String raw) {
    if (!raw.startsWith(prefix.value)) {
      throw FormatException('esperado prefixo "${prefix.value}", recebido "$raw"');
    }
    final body = raw.substring(prefix.value.length);
    if (body.length != 26 || !body.split('').every(_crockford.contains)) {
      throw FormatException('corpo ULID inválido em "$raw"');
    }
    return PrefixedId._(prefix, raw);
  }

  /// Gera um identificador novo no dispositivo. Usado para `scn_` e para o `evt_` que carimba
  /// cada linha do outbox local — a ordenação lexicográfica do ULID dá-nos a ordem de criação
  /// de graça, que é exatamente o que o motor de sincronização precisa.
  factory PrefixedId.generate(IdPrefix prefix, {DateTime? at, Random? random}) {
    final rng = random ?? Random.secure();
    final millis = (at ?? DateTime.now().toUtc()).millisecondsSinceEpoch;

    final time = StringBuffer();
    var remaining = millis;
    for (var i = 0; i < 10; i++) {
      time.write(_crockford[(remaining >> (5 * (9 - i))) & 0x1F]);
    }

    final entropy = StringBuffer();
    for (var i = 0; i < 16; i++) {
      entropy.write(_crockford[rng.nextInt(32)]);
    }

    return PrefixedId._(prefix, '${prefix.value}$time$entropy');
  }

  final IdPrefix prefix;
  final String value;

  /// Os 26 caracteres sem o prefixo. Só é preciso em telemetria interna; nunca vai para a rede.
  String get body => value.substring(prefix.value.length);

  /// Momento codificado nos primeiros 48 bits do ULID. Útil para mostrar "criado há 12 min" numa
  /// leitura que ainda está por sincronizar, sem ter de guardar um carimbo separado.
  DateTime get createdAt {
    var millis = 0;
    for (final ch in body.substring(0, 10).split('')) {
      millis = (millis << 5) | _crockford.indexOf(ch);
    }
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) => other is PrefixedId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Açúcar para desserializar campos obrigatórios de JSON sem repetir o `parse` em cada modelo.
extension PrefixedIdJson on Map<String, Object?> {
  PrefixedId id(String field, IdPrefix prefix) =>
      PrefixedId.parse(prefix, this[field]! as String);

  PrefixedId? optionalId(String field, IdPrefix prefix) {
    final raw = this[field];
    return raw == null ? null : PrefixedId.parse(prefix, raw as String);
  }
}
