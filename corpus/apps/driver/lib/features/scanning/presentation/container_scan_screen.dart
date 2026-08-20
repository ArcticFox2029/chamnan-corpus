// Ecrã de leitura de contentores: câmara, validação ISO 6346 e criação da leitura que vai para
// `POST /v1/containers/{container_id}/scans` assim que houver rede.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/driver_app.dart';
import '../../assignments/domain/assignment.dart';
import '../data/scan_repository.dart';
import '../domain/bic_container_code.dart';

/// Ecrã de leitura do contentor: câmara em cima, tipo de leitura em baixo. O código lido é
/// validado localmente (dígito de controlo ISO 6346) e só depois é que uma linha entra em
/// `local_scan_events` e na fila para o container-registry.
///
/// Há sempre um caminho manual. As placas dos contentores estão riscadas, cobertas de sal ou
/// pintadas por cima, e um ecrã que só aceite câmara faz o condutor desistir da leitura — que é
/// o pior resultado possível, porque a expedição fica sem rasto em `freight.shipment_scan_events`.
class ContainerScanScreen extends ConsumerStatefulWidget {
  const ContainerScanScreen({required this.assignment, super.key});

  final Assignment assignment;

  @override
  ConsumerState<ContainerScanScreen> createState() => _ContainerScanScreenState();
}

class _ContainerScanScreenState extends ConsumerState<ContainerScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    // A placa está muitas vezes em contraluz contra o céu; a lanterna resolve mais casos do que
    // qualquer ajuste de exposição.
    torchEnabled: false,
  );

  ScanType _type = ScanType.gateIn;
  BicContainerCode? _code;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || _saving) return;

    final (code, rejection) = BicContainerCode.tryParse(raw);
    setState(() {
      _code = code;
      _error = rejection == null ? null : _explain(rejection);
    });
  }

  String _explain(BicRejection rejection) => switch (rejection) {
        BicRejection.length => 'O código tem de ter 11 caracteres.',
        BicRejection.ownerCode => 'As três primeiras posições têm de ser letras.',
        BicRejection.category => 'A quarta letra tem de ser U, J ou Z.',
        BicRejection.serial => 'As seis posições do número de série têm de ser dígitos.',
        BicRejection.checkDigit =>
          'Dígito de controlo errado — provavelmente 0/O ou 1/I trocados. Confirme na placa.',
      };

  Future<void> _confirm() async {
    final code = _code;
    if (code == null) return;

    setState(() => _saving = true);
    final locator = ref.read(serviceLocatorProvider);

    // O `cnt_` é resolvido pelo container-registry a partir do `iso_code`; a app não o inventa.
    // Enquanto não houver rede, a leitura segue com o código BIC nas notas e o serviço faz a
    // ligação quando a linha chegar.
    final scanId = await locator.get<ScanRepository>().recordScan(
          shipmentId: widget.assignment.shipmentId,
          type: _type,
          notes: 'iso_code=${code.value}',
        );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Leitura ${_type.wire} guardada (${scanId.value.substring(0, 12)}…)')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ler contentor'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: _controller.toggleTorch,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: MobileScanner(controller: _controller, onDetect: _onDetect),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    _code?.pretty ?? 'Aponte a câmara à placa do contentor',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 16),
                  SegmentedButton<ScanType>(
                    segments: const <ButtonSegment<ScanType>>[
                      ButtonSegment<ScanType>(value: ScanType.gateIn, label: Text('Entrada')),
                      ButtonSegment<ScanType>(value: ScanType.load, label: Text('Carga')),
                      ButtonSegment<ScanType>(value: ScanType.unload, label: Text('Descarga')),
                      ButtonSegment<ScanType>(value: ScanType.gateOut, label: Text('Saída')),
                    ],
                    selected: <ScanType>{_type},
                    onSelectionChanged: (selection) => setState(() => _type = selection.first),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _code == null || _saving ? null : _confirm,
                    child: const Text('Guardar leitura'),
                  ),
                  TextButton(
                    onPressed: _saving ? null : _promptManualEntry,
                    child: const Text('Introduzir o código à mão'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _promptManualEntry() async {
    final controller = TextEditingController();
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Código do contentor'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'MSCU3948571'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );

    if (typed == null) return;
    final (code, rejection) = BicContainerCode.tryParse(typed);
    setState(() {
      _code = code;
      _error = rejection == null ? null : _explain(rejection);
    });
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
