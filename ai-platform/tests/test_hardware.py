from __future__ import annotations

from copy import deepcopy

import pytest

from app.hardware import analyze_capacity, compare_snapshots, total_gpu_vram_gb


GIB = 1024**3


def snapshot(*, cores=8, ram=32, storage=500, gpus=None, driver="575.57"):
    return {
        "cpu": {"model": "Example CPU", "cores": cores},
        "memory": {"total_bytes": ram * GIB},
        "storage": {"total_bytes": storage * GIB},
        "gpus": gpus or [],
        "gpu_driver": {"vendor": "NVIDIA", "version": driver},
    }


def gpu(index, uuid, name="RTX", vram=24):
    return {"index": index, "uuid": uuid, "vendor": "NVIDIA", "name": name, "memory_total_bytes": vram * GIB}


def test_no_hardware_change():
    current = snapshot(gpus=[gpu(0, "GPU-a")])
    result = compare_snapshots(current, deepcopy(current))
    assert result["changed"] is False
    assert result["requires_model_review"] is False


def test_gpu_addition_and_removal_are_classified():
    one = snapshot(gpus=[gpu(0, "GPU-a")])
    two = snapshot(gpus=[gpu(0, "GPU-a"), gpu(1, "GPU-b")])
    upgrade = compare_snapshots(one, two)
    downgrade = compare_snapshots(two, one)
    assert upgrade["upgrade_detected"] is True
    assert any(change["kind"] == "added" for change in upgrade["changes"])
    assert downgrade["downgrade_detected"] is True
    assert downgrade["requires_model_review"] is True


def test_model_vram_driver_cpu_and_ram_changes():
    old = snapshot(cores=8, ram=32, gpus=[gpu(0, "GPU-a", "Old GPU", 16)], driver="550.1")
    new = snapshot(cores=16, ram=64, gpus=[gpu(0, "GPU-a", "New GPU", 24)], driver="575.2")
    fields = {change["field"] for change in compare_snapshots(old, new)["changes"]}
    assert {"cpu.cores", "memory.total_bytes", "gpu.name", "gpu.memory_total_bytes", "gpu_driver.version"} <= fields


@pytest.mark.parametrize("old_vram,new_vram", [(4, 8), (8, 24), (24, 8)])
def test_required_vram_upgrade_and_downgrade_scenarios(old_vram, new_vram):
    result = compare_snapshots(
        snapshot(gpus=[gpu(0, "GPU-a", vram=old_vram)]),
        snapshot(gpus=[gpu(0, "GPU-a", vram=new_vram)]),
    )
    assert result["changed"] is True
    assert result["upgrade_detected"] is (new_vram > old_vram)
    assert result["downgrade_detected"] is (new_vram < old_vram)


def test_downgraded_ram_and_vram_require_review():
    old = snapshot(ram=64, gpus=[gpu(0, "GPU-a", vram=24)])
    new = snapshot(ram=32, gpus=[gpu(0, "GPU-a", vram=12)])
    result = compare_snapshots(old, new)
    assert result["downgrade_detected"] is True
    assert result["requires_model_review"] is True


def test_no_gpu_and_amd_only_are_gracefully_incompatible():
    no_gpu = snapshot(gpus=[])
    amd = snapshot(gpus=[])
    amd["gpu_driver"] = {"vendor": "AMD", "available": True, "version": None, "rocm_status": "detected-not-configured"}
    for item in (no_gpu, amd):
        result = analyze_capacity(item, 1, 2048, 1, [], 0.9)
        assert result["safe"] is False
        assert result["label"] == "INCOMPATIBLE"


def test_multi_gpu_capacity_and_missing_assignment():
    item = snapshot(gpus=[gpu(0, "GPU-a", vram=16), gpu(1, "GPU-b", vram=24)])
    assert total_gpu_vram_gb(item, [0, 1]) == 40
    assert analyze_capacity(item, 10, 4096, 2, [0, 1], 0.9)["safe"] is True
    missing = analyze_capacity(item, 1, 1024, 1, [7], 0.9)
    assert missing["safe"] is False
    assert missing["missing_gpu_indexes"] == [7]


def test_heterogeneous_gpu_capacity_uses_smallest_device_limit():
    item = snapshot(gpus=[gpu(0, "GPU-a", vram=24), gpu(1, "GPU-b", vram=4)])
    result = analyze_capacity(item, 10, 4096, 2, [0, 1], 0.9)
    assert result["safe"] is False
    assert result["safe_available_vram_gb"] == 7.2

