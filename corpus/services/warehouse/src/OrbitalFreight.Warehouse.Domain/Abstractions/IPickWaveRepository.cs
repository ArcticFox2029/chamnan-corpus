using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Domain.Abstractions;

/// <summary>
/// Dostęp do <c>warehouse.pick_waves</c> i <c>warehouse.pick_tasks</c>. Kolejność zadań w fali
/// jest zapisana w kolumnie <c>seq_no</c> i po wydaniu fali nie wolno jej przeliczać — magazynier
/// idzie halą według kartki, którą dostał, a nie według tego, co planer wymyślił minutę później.
/// </summary>
public interface IPickWaveRepository
{
    /// <summary>Zapisuje falę razem z kompletem zadań w jednym przebiegu.</summary>
    /// <param name="wave">Nagłówek fali.</param>
    /// <param name="tasks">Zadania w kolejności trasy; <c>seq_no</c> musi być ciągłe od 1.</param>
    /// <param name="ct">Token anulowania.</param>
    Task AddWaveAsync(PickWave wave, IReadOnlyList<PickTask> tasks, CancellationToken ct);

    /// <summary>Nagłówek fali albo <see langword="null"/>.</summary>
    Task<PickWave?> FindWaveAsync(string waveId, CancellationToken ct);

    /// <summary>Zadania fali w kolejności <c>seq_no</c>.</summary>
    Task<IReadOnlyList<PickTask>> GetTasksAsync(string waveId, CancellationToken ct);

    /// <summary>Pojedyncze zadanie po kluczu — używane przez potwierdzenie z terminala.</summary>
    Task<PickTask?> FindTaskAsync(string taskId, CancellationToken ct);

    /// <summary>
    /// Kontenery, które już są zaklepane przez otwarte fale. Planer musi je wykluczyć, inaczej
    /// dwie fale wysłałyby dwóch ludzi po ten sam kontener.
    /// </summary>
    Task<IReadOnlySet<string>> GetContainersInOpenWavesAsync(string facilityId, CancellationToken ct);

    /// <summary>Zmienia stan fali; przejścia pilnuje warstwa aplikacji, nie repozytorium.</summary>
    Task UpdateWaveStateAsync(
        string waveId,
        PickWaveState state,
        DateTimeOffset? releasedAt,
        DateTimeOffset? completedAt,
        CancellationToken ct);

    /// <summary>
    /// Zamyka zadanie. <paramref name="scanId"/> pochodzi z odpowiedzi container-registry na
    /// <c>POST /v1/containers/{container_id}/scans</c> i jest jedynym dowodem, że kontener
    /// naprawdę opuścił gniazdo.
    /// </summary>
    Task CompleteTaskAsync(
        string taskId,
        PickTaskState state,
        string? scanId,
        DateTimeOffset completedAt,
        CancellationToken ct);

    /// <summary>Czy w fali zostały jeszcze zadania otwarte — decyduje o przejściu w <c>completed</c>.</summary>
    Task<bool> HasOpenTasksAsync(string waveId, CancellationToken ct);

    /// <summary>
    /// Anuluje fale przypięte do przesyłki. Wywoływane przez konsumenta
    /// <c>shipment.status.changed</c>, gdy przesyłka wpada w <c>cancelled</c>.
    /// </summary>
    /// <returns>Liczba anulowanych fal.</returns>
    Task<int> CancelWavesForShipmentAsync(string shipmentId, string reasonCode, CancellationToken ct);
}
