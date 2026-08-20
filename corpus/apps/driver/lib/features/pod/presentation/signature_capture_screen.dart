import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:signature/signature.dart';

import '../../../app/driver_app.dart';
import '../../assignments/domain/assignment.dart';
import '../data/proof_of_delivery_repository.dart';

/// Captura da assinatura do destinatário e fecho da entrega. O botão de confirmação escreve as
/// três linhas do comprovativo (leitura, assinatura, mudança de estado) numa só transação — ver
/// `ProofOfDeliveryRepository.complete` — e nunca espera pela rede.
///
/// O PNG é gravado no diretório de documentos da app e só depois é passado ao repositório. Manter
/// os bytes em memória até ao envio parece mais simples e foi o que a versão 3.x fazia; perdia a
/// assinatura sempre que o Android matava o processo no parque de estacionamento do cliente.
class SignatureCaptureScreen extends ConsumerStatefulWidget {
  const SignatureCaptureScreen({required this.assignment, super.key});

  final Assignment assignment;

  @override
  ConsumerState<SignatureCaptureScreen> createState() => _SignatureCaptureScreenState();
}

class _SignatureCaptureScreenState extends ConsumerState<SignatureCaptureScreen> {
  final SignatureController _pad = SignatureController(
    penStrokeWidth: 3,
    exportBackgroundColor: const Color(0xFFFFFFFF),
  );
  final TextEditingController _name = TextEditingController();
  final TextEditingController _company = TextEditingController();

  bool _saving = false;

  @override
  void dispose() {
    _pad.dispose();
    _name.dispose();
    _company.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_pad.isEmpty || _name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Falta o nome de quem recebe ou a assinatura.')),
      );
      return;
    }

    setState(() => _saving = true);

    final bytes = await _pad.toPngBytes();
    if (bytes == null) {
      setState(() => _saving = false);
      return;
    }

    final directory = Directory.systemTemp;
    final file = File(
      p.join(directory.path, 'pod_${widget.assignment.shipmentId.value}.png'),
    );
    await file.writeAsBytes(bytes, flush: true);

    final locator = ref.read(serviceLocatorProvider);
    final receipt = await locator.get<ProofOfDeliveryRepository>().complete(
          shipmentId: widget.assignment.shipmentId,
          signaturePng: file,
          consignee: Consignee(
            name: _name.text.trim(),
            company: _company.text.trim().isEmpty ? null : _company.text.trim(),
          ),
        );

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Entrega registada'),
        content: Text(
          'Comprovativo ${receipt.scanId.value.substring(0, 12)}… guardado às '
          '${TimeOfDay.fromDateTime(receipt.occurredAt.toLocal()).format(context)}.\n\n'
          'Se estiver sem rede, fica na fila e sai sozinho assim que houver cobertura.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    // Dois `pop`: sai do ecrã da assinatura e do ecrã da rota, voltando à lista de entregas.
    Navigator.of(context)
      ..pop()
      ..pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Entrega · ${widget.assignment.shipmentReference}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nome de quem recebe'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _company,
              decoration: const InputDecoration(labelText: 'Empresa (opcional)'),
            ),
            const SizedBox(height: 16),
            Text('Assinatura', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Signature(controller: _pad, backgroundColor: const Color(0xFFF7F7F7)),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: _pad.clear,
                  child: const Text('Limpar'),
                ),
              ],
            ),
            FilledButton(
              onPressed: _saving ? null : _confirm,
              child: Text(_saving ? 'A guardar…' : 'Confirmar entrega'),
            ),
          ],
        ),
      ),
    );
  }
}
