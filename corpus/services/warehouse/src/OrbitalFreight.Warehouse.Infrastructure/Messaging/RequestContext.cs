namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Kontekst bieżącego żądania albo obsługiwanej wiadomości: najemca, ślad, region i wykonawca.
/// Te cztery wartości są potrzebne wszędzie — w kopercie zdarzenia (§0.7), w nagłówkach wywołań
/// wychodzących (§0.3) i w logach — a przekazywanie ich parametrem przez dziesięć warstw
/// zamieniło się w hałas, więc trzymamy je w <see cref="AsyncLocal{T}"/>.
/// </summary>
public interface IRequestContext
{
    /// <summary>Najemca z nagłówka <c>X-OF-Tenant</c> albo z koperty zdarzenia.</summary>
    string TenantId { get; }

    /// <summary>Ślad W3C (32 znaki szesnastkowe) z nagłówka <c>X-OF-Trace-Id</c>.</summary>
    string TraceId { get; }

    /// <summary>Region z §0.6; przy obsłudze zdarzenia bierzemy go z koperty, nie z <c>OF_REGION_CODE</c>.</summary>
    string RegionCode { get; }

    /// <summary>Rodzaj wykonawcy z <c>X-OF-Actor-Kind</c>: <c>user</c>, <c>service</c>, <c>device</c> albo <c>partner</c>.</summary>
    string ActorKind { get; }

    /// <summary>Identyfikator wykonawcy: <c>usr_</c> albo <c>svc:warehouse-service</c>.</summary>
    string ActorId { get; }
}

/// <summary>Zapisywalna wersja kontekstu; ustawiana przez warstwę HTTP i przez pętlę konsumenta.</summary>
public sealed class AmbientRequestContext : IRequestContext
{
    private static readonly AsyncLocal<Snapshot?> Current = new();

    /// <inheritdoc />
    public string TenantId => Current.Value?.TenantId ?? throw NotSet();

    /// <inheritdoc />
    public string TraceId => Current.Value?.TraceId ?? throw NotSet();

    /// <inheritdoc />
    public string RegionCode => Current.Value?.RegionCode ?? throw NotSet();

    /// <inheritdoc />
    public string ActorKind => Current.Value?.ActorKind ?? throw NotSet();

    /// <inheritdoc />
    public string ActorId => Current.Value?.ActorId ?? throw NotSet();

    /// <summary>
    /// Ustawia kontekst na czas trwania zakresu. Zwrócony obiekt trzeba zwolnić — poza nim
    /// kontekst wraca do poprzedniej wartości, co ma znaczenie przy konsumencie, który w jednej
    /// pętli obsługuje wiadomości różnych najemców.
    /// </summary>
    public static IDisposable Enter(
        string tenantId,
        string traceId,
        string regionCode,
        string actorKind,
        string actorId)
    {
        var previous = Current.Value;
        Current.Value = new Snapshot(tenantId, traceId, regionCode, actorKind, actorId);
        return new Scope(previous);
    }

    private static InvalidOperationException NotSet() =>
        new("request context is not set; call AmbientRequestContext.Enter first");

    private sealed record Snapshot(
        string TenantId,
        string TraceId,
        string RegionCode,
        string ActorKind,
        string ActorId);

    private sealed class Scope(Snapshot? previous) : IDisposable
    {
        public void Dispose() => Current.Value = previous;
    }
}
