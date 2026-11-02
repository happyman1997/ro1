"""Проверка сцены в собранном файле места (rojo build → .rbxlx).

Проверяет договорённости, на которые опирается код (docs/ARCHITECTURE.md, раздел «Сцена»):
  • для каждого уровня из Config/Tiers есть модель ServerStorage.Restaurants.<Model>;
  • в каждой модели уровня ровно одна касса (тег CashRegister) и есть мебель (тег Furniture);
  • в каждой модели уровня есть маршрут клиентов: CustomerSpawn, ровно одна CustomerDoor
    и CustomerOrder не меньше MaxCustomers из Config/Tiers;
  • у каждого защитника (тег Guard/Turret) атрибут DefenderType из Config/Defense
    и деталь, откуда он смотрит (Head или HumanoidRootPart);
  • в Workspace есть участки (тег Plot) с деталями Origin и Territory;
  • для каждого оружия из Config/Weapons есть Tool ServerStorage.Weapons.<id>
    с деталью Handle и атрибутом WeaponId = <id>;
  • для каждого типа охраны есть шаблон ServerStorage.Defenders.<тип> с нужным тегом;
  • слоты охраны (тег DefenseSlot) имеют SlotId и SlotKind, SlotId уникальны в уровне.

Запуск: python3 tools/check_scene.py путь/к/месту.rbxlx
"""

import base64
import re
import struct
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
BASE_PARTS = {"Part", "MeshPart", "WedgePart", "CornerWedgePart", "TrussPart", "SpawnLocation", "Seat", "UnionOperation"}


def config_keys(path: Path, pattern: str) -> set[str]:
    return set(re.findall(pattern, path.read_text(encoding="utf-8"), re.M))


def prop(item, tag, name):
    props = item.find("Properties")
    return props.find(f"{tag}[@name='{name}']") if props is not None else None


def name_of(item) -> str:
    node = prop(item, "string", "Name")
    return node.text if node is not None and node.text else "?"


def tags_of(item) -> set[str]:
    node = prop(item, "BinaryString", "Tags")
    if node is None or not (node.text or "").strip():
        return set()
    return {t for t in base64.b64decode(node.text.strip()).decode("utf-8").split("\x00") if t}


def attributes_of(item) -> dict:
    """Разбор AttributesSerialize: строки, логические значения и числа."""
    node = prop(item, "BinaryString", "AttributesSerialize")
    if node is None or not (node.text or "").strip():
        return {}
    raw = base64.b64decode(node.text.strip())
    result, offset = {}, 4
    (count,) = struct.unpack_from("<I", raw, 0)
    for _ in range(count):
        (length,) = struct.unpack_from("<I", raw, offset)
        key = raw[offset + 4 : offset + 4 + length].decode("utf-8")
        offset += 4 + length
        kind = raw[offset]
        offset += 1
        if kind == 0x02:  # string
            (length,) = struct.unpack_from("<I", raw, offset)
            result[key] = raw[offset + 4 : offset + 4 + length].decode("utf-8")
            offset += 4 + length
        elif kind == 0x03:  # bool
            result[key] = raw[offset] != 0
            offset += 1
        elif kind == 0x06:  # double
            (result[key],) = struct.unpack_from("<d", raw, offset)
            offset += 8
        else:
            break  # другие типы этой проверке не нужны
    return result


def walk(item, path=""):
    path = f"{path}/{name_of(item)}"
    yield path, item
    for child in item.findall("Item"):
        yield from walk(child, path)


def child(item, name):
    return next((c for c in item.findall("Item") if name_of(c) == name), None)


def main(place: str) -> int:
    tier_models = config_keys(ROOT / "src/shared/Config/Tiers.luau", r'^\s*Model = "([^"]+)"')
    tiers_text = (ROOT / "src/shared/Config/Tiers.luau").read_text(encoding="utf-8")
    max_customers = dict(re.findall(r'Model = "([^"]+)".*?MaxCustomers = (\d+)', tiers_text, re.S))
    defender_types = config_keys(ROOT / "src/shared/Config/Defense.luau", r"^\t(\w+) = \{")
    weapon_ids = config_keys(ROOT / "src/shared/Config/Weapons.luau", r"^\t(\w+) = \{")
    root = ET.parse(place).getroot()
    services = {item.get("class"): item for item in root.findall("Item")}
    errors: list[str] = []

    # Модели уровней.
    storage = services.get("ServerStorage")
    restaurants = child(storage, "Restaurants") if storage is not None else None
    if restaurants is None:
        errors.append("нет папки ServerStorage.Restaurants")
    else:
        for model_name in sorted(tier_models):
            model = child(restaurants, model_name)
            where = f"ServerStorage.Restaurants.{model_name}"
            if model is None or model.get("class") != "Model":
                errors.append(f"{where}: нет модели уровня (Model)")
                continue
            items = list(walk(model))
            registers = [p for p, i in items if "CashRegister" in tags_of(i)]
            if len(registers) != 1:
                errors.append(f"{where}: касс с тегом CashRegister — {len(registers)}, нужна ровно одна")
            if not any("Furniture" in tags_of(i) for _, i in items):
                errors.append(f"{where}: нет мебели с тегом Furniture")
            slot_ids = []
            for path, item in items:
                if "DefenseSlot" in tags_of(item):
                    attrs = attributes_of(item)
                    if not isinstance(attrs.get("SlotId"), str) or attrs.get("SlotKind") not in ("Guard", "Turret"):
                        errors.append(f"{path}: у слота нужны SlotId и SlotKind (Guard/Turret)")
                    slot_ids.append(attrs.get("SlotId"))
            duplicates = sorted({s for s in slot_ids if slot_ids.count(s) > 1 and s})
            if duplicates:
                errors.append(f"{where}: повторяются SlotId {duplicates}")
            def count(tag):
                return sum(1 for _, i in items if tag in tags_of(i))
            if count("CustomerSpawn") < 1:
                errors.append(f"{where}: нет точки появления клиентов (тег CustomerSpawn)")
            if count("CustomerDoor") != 1:
                errors.append(f"{where}: точек CustomerDoor — {count('CustomerDoor')}, нужна ровно одна")
            need = int(max_customers.get(model_name, 0))
            if need == 0:
                errors.append(f"{where}: в Config/Tiers нет MaxCustomers для этого уровня")
            elif count("CustomerOrder") < need:
                errors.append(f"{where}: мест у стойки (CustomerOrder) {count('CustomerOrder')}, а MaxCustomers = {need}")

    # Оружие.
    weapons = child(storage, "Weapons") if storage is not None else None
    for weapon_id in sorted(weapon_ids):
        tool = child(weapons, weapon_id) if weapons is not None else None
        where = f"ServerStorage.Weapons.{weapon_id}"
        if tool is None or tool.get("class") != "Tool":
            errors.append(f"{where}: нет шаблона оружия (Tool)")
            continue
        handle = child(tool, "Handle")
        if handle is None or handle.get("class") not in BASE_PARTS:
            errors.append(f"{where}: нет детали Handle")
        if attributes_of(tool).get("WeaponId") != weapon_id:
            errors.append(f"{where}: атрибут WeaponId должен быть {weapon_id!r}")

    # Шаблоны наёмной охраны.
    defense_kinds = dict(re.findall(r'^\t(\w+) = \{[^}]*?Kind = "(\w+)"', (ROOT / "src/shared/Config/Defense.luau").read_text(encoding="utf-8"), re.M | re.S))
    defenders = child(storage, "Defenders") if storage is not None else None
    for defender_type in sorted(defender_types):
        template = child(defenders, defender_type) if defenders is not None else None
        where = f"ServerStorage.Defenders.{defender_type}"
        expected_tag = "Turret" if defense_kinds.get(defender_type) == "Turret" else "Guard"
        if template is None or template.get("class") != "Model":
            errors.append(f"{where}: нет шаблона охраны (Model)")
        elif expected_tag not in tags_of(template):
            errors.append(f"{where}: нужен тег {expected_tag}")

    # Защитники везде, где они могут оказаться.
    for service in services.values():
        for path, item in walk(service):
            item_tags = tags_of(item)
            if not item_tags & {"Guard", "Turret"}:
                continue
            defender = attributes_of(item).get("DefenderType")
            if defender not in defender_types:
                errors.append(f"{path}: DefenderType = {defender!r}, ожидается одно из {sorted(defender_types)}")
            eyes = [child(item, n) for n in ("Head", "HumanoidRootPart")]
            if item.get("class") != "Model" or not any(e is not None and e.get("class") in BASE_PARTS for e in eyes):
                errors.append(f"{path}: защитник должен быть Model с деталью Head или HumanoidRootPart")

    # Участки.
    workspace = services.get("Workspace")
    plots = [(p, i) for p, i in walk(workspace)] if workspace is not None else []
    plots = [(p, i) for p, i in plots if "Plot" in tags_of(i)]
    if not plots:
        errors.append("в Workspace нет участков с тегом Plot")
    for path, plot in plots:
        for required in ("Origin", "Territory"):
            part = child(plot, required)
            if part is None or part.get("class") not in BASE_PARTS:
                errors.append(f"{path}: нет детали {required}")

    if errors:
        print("Сцена не соответствует договорённостям:")
        for error in errors:
            print(f"  • {error}")
        return 1
    print(
        f"Сцена в порядке: уровней {len(tier_models)}, участков {len(plots)}, "
        f"типов охраны {len(defender_types)}, оружия {len(weapon_ids)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
