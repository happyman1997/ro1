"""Генератор тестовой карты ro1: scene/Restaurants, scene/Plots, scene/Weapons, scene/Defenders.

Запуск из корня репозитория:  python3 tools/gen_scene.py .
Файлы в scene/ — результат этого скрипта. Меняйте сцену здесь и перегенерируйте,
а не правьте JSON руками. Настоящие модели из Studio заменят тестовые позже.
"""
import json, os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
I = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
FACE_PLUS_Z = [[-1, 0, 0], [0, 1, 0], [0, 0, -1]]  # поворот на 180° вокруг Y: LookVector = +Z


def cframe(pos, rot=I):
    return {"CFrame": {"position": [round(v, 3) for v in pos], "orientation": rot}}


def part(name, size, pos, color, material="SmoothPlastic", rot=I, transparency=0, tags=None, attrs=None,
         children=None, cls="Part", extra=None):
    props = {
        "Anchored": True,
        "Size": [round(v, 3) for v in size],
        "CFrame": cframe(pos, rot),
        "Color": [round(c, 3) for c in color],
        "Material": material,
        "TopSurface": "Smooth",
        "BottomSurface": "Smooth",
    }
    if transparency:
        props["Transparency"] = transparency
    if tags:
        props["Tags"] = tags
    if extra:
        props.update(extra)
    if attrs:
        props["Attributes"] = typed_attributes(attrs)
    node = {"Name": name, "ClassName": cls, "Properties": props}
    if children:
        node["Children"] = children
    return node


def typed_attributes(attrs):
    """Атрибуты в явной форме Rojo для .model.json: {"Attributes": {имя: {Тип: значение}}}."""
    out = {}
    for key, value in attrs.items():
        if isinstance(value, bool):
            out[key] = {"Bool": value}
        elif isinstance(value, (int, float)):
            out[key] = {"Float64": float(value)}
        else:
            out[key] = {"String": str(value)}
    return {"Attributes": out}


def folder(name, children):
    return {"Name": name, "ClassName": "Folder", "Children": children}


def attachment(name, pos):
    return {"Name": name, "ClassName": "Attachment", "Properties": {"CFrame": cframe(pos)}}


TIERS = {
    "Tier1": dict(W=14, D=10, H=8, wall=("WoodPlanks", (0.55, 0.38, 0.22), {"ShootThrough": True, "MaxHealth": 120}),
                  front=None, slots=[("Door1", "Guard", 5, 2.5)], tables=0, customers=2),
    "Tier2": dict(W=20, D=16, H=10, wall=("Brick", (0.62, 0.32, 0.26), {"MaxHealth": 600}),
                  front=("Glass", (0.7, 0.85, 0.95), 0.6, {"SeeThrough": True, "ShootThrough": True, "MaxHealth": 40}),
                  slots=[("Door1", "Guard", 8, 5.5), ("Hall1", "Guard", 0, -4)], tables=2, customers=3),
    "Tier3": dict(W=26, D=20, H=12, wall=("Concrete", (0.78, 0.78, 0.78), {"ArmoredHealth": 600}),
                  front=("Glass", (0.55, 0.75, 0.9), 0.45, {"SeeThrough": True}),
                  slots=[("Door1", "Guard", 11, 7.5), ("Hall1", "Guard", 0, -5), ("Ceiling1", "Turret", 0, -2)], tables=4,
                  customers=4),
    "Tier4": dict(W=30, D=24, H=12, wall=("DiamondPlate", (0.35, 0.37, 0.4), {"ArmoredHealth": 900}),
                  front=("DiamondPlate", (0.25, 0.27, 0.3), 0, {"ArmoredHealth": 900}),
                  slots=[("Door1", "Guard", 13, 9.5), ("Hall1", "Guard", 0, -6),
                         ("Ceiling1", "Turret", -7.5, 0), ("Ceiling2", "Turret", 7.5, 0)], tables=4, customers=4),
}
DOOR = 6
T = 0.6  # толщина стен
FLOOR = 0.4


def marker(name, pos, tag, attrs=None):
    """Невидимая точка-метка: лучи, касания и столкновения её не замечают."""
    return part(name, (1, 0.2, 1), pos, (0.3, 1, 0.4), transparency=1, tags=[tag], attrs=attrs,
                extra={"CanCollide": False, "CanQuery": False, "CanTouch": False})


def restaurant(name, W, D, H, wall, front, slots, tables, customers):
    wall_mat, wall_color, wall_attrs = wall
    y_wall = FLOOR + H / 2
    structure = [
        part("Floor", (W, FLOOR, D), (0, FLOOR / 2, 0), (0.45, 0.42, 0.38), "WoodPlanks" if name == "Tier1" else "Slate"),
        part("BackWall", (W, H, T), (0, y_wall, -D / 2), wall_color, wall_mat, attrs=wall_attrs or None),
        part("LeftWall", (T, H, D), (-W / 2, y_wall, 0), wall_color, wall_mat, attrs=wall_attrs or None),
        part("RightWall", (T, H, D), (W / 2, y_wall, 0), wall_color, wall_mat, attrs=wall_attrs or None),
        part("Roof", (W + 1, 0.4, D + 1), (0, FLOOR + H + 0.2, 0), (0.3, 0.3, 0.32), "Slate"),
        # Козырёк над входом: перекрывает обзор снайперам с крыш на вход.
        part("Canopy", (W + 2, 0.4, 6), (0, FLOOR + H - 0.5, D / 2 + 3), (0.75, 0.2, 0.2), "Fabric"),
    ]
    if front:
        mat, color, transparency, attrs = front
        seg = (W - DOOR) / 2
        x = DOOR / 2 + seg / 2
        for side, sx in (("FrontLeft", -x), ("FrontRight", x)):
            structure.append(part(side, (seg, H, T), (sx, y_wall, D / 2), color, mat,
                                  transparency=transparency, attrs=attrs or None))

    counter_z = D / 2 - (1.2 if front is None else 3)
    counter_w = min(8, W * 0.45)
    furniture = [
        part("Counter", (counter_w, 3, 1.5), (0, FLOOR + 1.5, counter_z), (0.6, 0.45, 0.3), "Wood", tags=["Furniture"],
             attrs={"MaxHealth": 150}),
        part("Stove", (3, 3, 2), (-W / 2 + 2.5, FLOOR + 1.5, -D / 2 + 1.8), (0.2, 0.2, 0.22), "Metal", tags=["Furniture"],
             attrs={"MaxHealth": 200}),
    ]
    spots = [(-W / 4 - 1, -D / 8), (W / 4 + 1, -D / 8), (-W / 4 - 1, -D / 3), (W / 4 + 1, -D / 3)]
    for i, (tx, tz) in enumerate(spots[:tables]):
        furniture.append(part(f"Table{i + 1}", (4, 2, 3), (tx, FLOOR + 1, tz), (0.85, 0.85, 0.8), "Wood", tags=["Furniture"],
                              attrs={"MaxHealth": 80}))

    # Касса — тоже мебель: разбитая касса останавливает ресторан. Её можно разбить пулями.
    register = part("CashRegister", (2, 1.2, 1.5), (counter_w / 2 - 1.5, FLOOR + 3.6, counter_z), (0.2, 0.6, 0.3),
                    "SmoothPlastic", tags=["CashRegister", "Furniture"], attrs={"MaxHealth": 300})

    # Охранник-стрелок у входа, смотрит на дверь (+Z). Без Humanoid: в тестовой сцене
    # он неуязвим, этого достаточно, чтобы проверить обнаружение и стрельбу.
    gx, gz = -(W / 2 - 2), D / 2 - 2.5
    guard = {
        "Name": "Gunner", "ClassName": "Model",
        "Properties": {"Tags": ["Guard"], "Attributes": typed_attributes({"DefenderType": "Gunner"})},
        "Children": [
            part("HumanoidRootPart", (2, 5, 1), (gx, FLOOR + 2.5, gz), (0.15, 0.2, 0.45), "SmoothPlastic",
                 rot=FACE_PLUS_Z, children=[attachment("Muzzle", (0.8, 1.2, -0.8))]),
            # Голова — «глаза» охранника, выше стойки (иначе стойка закрывала бы обзор).
            part("Head", (1.2, 1.2, 1.2), (gx, FLOOR + 5.6, gz), (0.95, 0.8, 0.65), "SmoothPlastic", rot=FACE_PLUS_Z),
        ],
    }
    guards = [guard]

    # Повар у плиты: персонал ресторана. Убит — ресторан стоит до ремонта.
    chef = {
        "Name": "Chef", "ClassName": "Model",
        "Properties": {"Tags": ["Staff"]},
        "Children": [
            {"Name": "Humanoid", "ClassName": "Humanoid",
             "Properties": {"RequiresNeck": False, "BreakJointsOnDeath": False}},
            part("HumanoidRootPart", (2, 5, 1), (-W / 2 + 5.5, FLOOR + 2.5, -D / 2 + 2), (0.95, 0.95, 0.95)),
            part("Head", (1.2, 1.2, 1.2), (-W / 2 + 5.5, FLOOR + 5.6, -D / 2 + 2), (0.95, 0.8, 0.65)),
        ],
    }

    # Слоты для найма охраны: невидимые метки. Охранники смотрят на вход (+Z),
    # турели висят под потолком.
    slot_parts = []
    for slot_id, kind, sx, sz in slots:
        y = FLOOR if kind == "Guard" else FLOOR + H - 0.8
        slot_parts.append(part(f"Slot_{slot_id}", (1, 0.2, 1), (sx, y, sz), (0.2, 0.8, 1), rot=FACE_PLUS_Z,
                               transparency=1, tags=["DefenseSlot"], attrs={"SlotId": slot_id, "SlotKind": kind},
                               extra={"CanCollide": False, "CanQuery": False, "CanTouch": False}))

    # Маршрут NPC-клиентов: появление под козырьком по бокам → у двери → место у стойки.
    # Места у стойки идут слева направо через 2 студа (касса — справа).
    customer_points = [
        marker("Spawn1", (-(W / 2 - 1), FLOOR, D / 2 + 4), "CustomerSpawn"),
        marker("Spawn2", (W / 2 - 1, FLOOR, D / 2 + 4), "CustomerSpawn"),
        marker("Door", (0, FLOOR, D / 2 + 1.5), "CustomerDoor"),
    ]
    for i in range(customers):
        customer_points.append(marker(f"Order{i + 1}", (-counter_w / 2 + 1 + 2 * i, FLOOR, counter_z + 1.8),
                                      "CustomerOrder"))

    return {
        "ClassName": "Model",
        # Пивот в (0, 0, 0): PlotService ставит модель так, что эта точка совпадает с Plot.Origin.
        "Properties": {"WorldPivot": cframe((0, 0, 0))},
        "Children": [folder("Structure", structure), folder("Furniture", furniture), register, folder("Guards", guards),
                     folder("DefenseSlots", slot_parts), folder("Staff", [chef]),
                     folder("CustomerPoints", customer_points)],
    }


def plot(x):
    return {
        "ClassName": "Model",
        "Properties": {"Tags": ["Plot"], "WorldPivot": cframe((x, 0, 0))},
        "Children": [
            part("Origin", (1, 1, 1), (x, 0, 0), (1, 1, 1)),
            part("Territory", (60, 40, 60), (x, 20, 0), (1, 1, 1), transparency=1,
                 extra={"CanCollide": False, "CanTouch": False, "CanQuery": False}),
            # Площадка показывает границы территории на земле.
            part("Pad", (60, 0.2, 60), (x, 0.1, 0), (0.55, 0.53, 0.5), "Concrete"),
            part("Spawn", (6, 1, 6), (x, 0.7, 25), (0.9, 0.8, 0.3), cls="SpawnLocation",
                 extra={"Neutral": False, "AllowTeamChangeOnTouch": False, "Duration": 3}),
        ],
    }


def write(rel, data):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


WEAPONS = {
    "Pistol": ("Пистолет", (0.4, 1.2, 1.6), (0.2, 0.2, 0.22)),
    "Rifle": ("Автомат", (0.4, 1.0, 3.5), (0.25, 0.3, 0.2)),
    "Sniper": ("Снайперская винтовка", (0.4, 0.9, 5.0), (0.15, 0.17, 0.12)),
}


def weapon(weapon_id, title, size, color):
    return {
        "ClassName": "Tool",
        "Properties": {
            "ToolTip": title,
            "CanBeDropped": False,
            "Attributes": typed_attributes({"WeaponId": weapon_id}),
        },
        "Children": [
            {
                "Name": "Handle",
                "ClassName": "Part",
                "Properties": {
                    "Size": list(size),
                    "Color": list(color),
                    "Material": "Metal",
                    "CanCollide": False,
                },
            }
        ],
    }


def humanoid_guard(defender_type, color, with_muzzle):
    root_children = [attachment("Muzzle", (0.8, 1.2, -0.8))] if with_muzzle else None
    return {
        "ClassName": "Model",
        "Properties": {"Tags": ["Guard"], "Attributes": typed_attributes({"DefenderType": defender_type}),
                       "WorldPivot": cframe((0, 0, 0))},
        "Children": [
            {"Name": "Humanoid", "ClassName": "Humanoid", "Properties": {"RequiresNeck": False, "BreakJointsOnDeath": False}},
            part("HumanoidRootPart", (2, 5, 1), (0, 2.5, 0), color, children=root_children),
            part("Head", (1.2, 1.2, 1.2), (0, 5.6, 0), (0.95, 0.8, 0.65)),
        ],
    }


DEFENDERS = {
    "Bouncer": humanoid_guard("Bouncer", (0.1, 0.1, 0.12), False),
    "Gunner": humanoid_guard("Gunner", (0.15, 0.2, 0.45), True),
    "CeilingTurret": {
        "ClassName": "Model",
        "Properties": {"Tags": ["Turret"], "Attributes": typed_attributes({"DefenderType": "CeilingTurret"}),
                       "WorldPivot": cframe((0, 0, 0))},
        "Children": [part("Head", (1.6, 1, 1.6), (0, 0, 0), (0.1, 0.1, 0.1), "Metal",
                          children=[attachment("Muzzle", (0, 0, -1))])],
    },
}
for defender_type, model in DEFENDERS.items():
    write(f"scene/Defenders/{defender_type}.model.json", model)

for weapon_id, (title, size, color) in WEAPONS.items():
    write(f"scene/Weapons/{weapon_id}.model.json", weapon(weapon_id, title, size, color))

for name, spec in TIERS.items():
    write(f"scene/Restaurants/{name}.model.json", restaurant(name, **spec))
for i, x in enumerate((-105, -35, 35, 105), start=1):
    write(f"scene/Plots/Plot{i}.model.json", plot(x))
print("готово")
