#!/usr/bin/env python3
"""Standalone helper to export an iPhone pairing file for A Console Mobile.

Run via uvx (no global install needed):
  uvx --from pymobiledevice3==11.61.0 --python 3.14 python ios/tools/export_pairing.py
"""

import argparse
import asyncio
import os
from pathlib import Path
import plistlib
import sys

from pymobiledevice3 import usbmux
from pymobiledevice3.lockdown import create_using_usbmux


async def export_pairing(udid: str | None, output: Path | None) -> int:
    devices = [d for d in await usbmux.list_devices() if d.is_usb]
    if not devices:
        print("未检测到 USB 连接的 iPhone，请解锁并信任此电脑。", file=sys.stderr)
        return 1

    target_serial = udid or devices[0].serial
    async with await asyncio.wait_for(
        create_using_usbmux(serial=target_serial, connection_type="USB", pair_timeout=25),
        timeout=35,
    ) as lockdown:
        if lockdown.all_values.get("DeviceClass") != "iPhone":
            print(f"设备 {target_serial} 不是 iPhone。", file=sys.stderr)
            return 1
        record = getattr(lockdown, "pair_record", None)
        if not record:
            await lockdown.fetch_pair_record()
            record = getattr(lockdown, "pair_record", None)
        if not record:
            print("未找到配对记录，请解锁 iPhone 并确认「信任此电脑」。", file=sys.stderr)
            return 1

        await lockdown.set_enable_wifi_connections(True)
        name = lockdown.display_name or "iphone"
        dest = output or Path(f"{name}.mobiledevicepairing")
        dest = dest.expanduser().resolve()
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(f".{dest.name}.{os.getpid()}.tmp")
        tmp.write_bytes(plistlib.dumps(record))
        if sys.platform != "win32":
            os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
        print(f"已开启无线连接开关并导出配对文件：{dest}")
        print("注意：此文件等同于受信任电脑凭证，请仅传给自己的 iPhone 导入后删除原文件。")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Export iPhone pairing file for A Console Mobile")
    parser.add_argument("--udid", help="Target iPhone UDID (defaults to first connected USB iPhone)")
    parser.add_argument("-o", "--output", type=Path, help="Output .mobiledevicepairing path")
    args = parser.parse_args()
    return asyncio.run(export_pairing(args.udid, args.output))


if __name__ == "__main__":
    raise SystemExit(main())
