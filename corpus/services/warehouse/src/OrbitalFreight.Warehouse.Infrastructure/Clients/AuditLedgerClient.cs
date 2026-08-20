using System.Text.Json;
using Grpc.Net.Client;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;

namespace OrbitalFreight.Warehouse.Infrastructure.Clients;

/// <summary>
/// Klient audit-ledger. Każda korekta stanu magazynowego wynikająca z inwentaryzacji jest
/// dopisywana do <c>platform.audit_ledger_entries</c> przez <c>audit.v1.LedgerService/Append</c> —
/// to jedyna droga zapisu do tej tabeli i jedyny powód, dla którego audytor wierzy potem naszym
/// liczbom. Wpisy są niezmienne (§7 pkt 6): pomyłkę prostuje wpis kompensujący, nie edycja.
/// </summary>
/// <param name="channel">Kanał do <c>OF_AUDIT_LEDGER_GRPC_ADDR</c>.</param>
/// <param name="context">Kontekst żądania; z niego bierzemy najemcę i ślad.</param>
public sealed class AuditLedgerClient(GrpcChannel channel, IRequestContext context) : IAuditLedgerPort
{
    private readonly GrpcChannel _channel = channel;
    private readonly IRequestContext _context = context;

    /// <summary>Rodzaj podmiotu dla korekt gniazdowych.</summary>
    public const string SlotSubjectType = "warehouse_slot";

    /// <inheritdoc />
    public async Task<long> AppendAsync(
        string subjectType,
        string subjectId,
        string action,
        string actorId,
        IReadOnlyDictionary<string, object?> payload,
        CancellationToken ct)
    {
        var client = new Gen.Audit.V1.LedgerService.LedgerServiceClient(_channel);

        var request = new Gen.Audit.V1.AppendRequest
        {
            TenantId = _context.TenantId,
            SubjectType = subjectType,
            SubjectId = subjectId,
            Action = action,
            ActorId = actorId,
            ActorKind = _context.ActorKind,
            TraceId = _context.TraceId,
            PayloadJson = JsonSerializer.Serialize(payload, EventEnvelope<object>.SerializerOptions),
            OccurredAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
        };

        var reply = await client.AppendAsync(request, cancellationToken: ct);

        // entry_id jest BIGINT-em, a nie ULID-em — łańcuch skrótów rejestru wymaga porządku
        // całkowitego, więc tu jako jedyne miejsce na platformie odstępujemy od §0.1.
        return reply.EntryId;
    }
}
