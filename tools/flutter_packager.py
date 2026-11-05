#!/usr/bin/env python3
"""A small Tkinter GUI for building this Flutter project."""

from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import messagebox, ttk
from typing import Optional


PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = PROJECT_ROOT / ".flutter_packager.json"

PLATFORM_TARGETS = {
    "Android": {"APK": "apk", "AAB": "appbundle"},
    "macOS": {"App": "macos"},
    "Windows": {"App": "windows"},
}

APK_ARCHITECTURES = {
    "arm64": "android-arm64",
    "arm": "android-arm",
    "x86_64": "android-x64",
    "通用（全部架构）": None,
}


def parse_dart_defines(value: str) -> list[str]:
    """Convert comma/newline separated KEY=VALUE pairs to CLI arguments."""
    result = []
    for item in value.replace(",", "\n").splitlines():
        item = item.strip()
        if not item:
            continue
        if "=" not in item or not item.split("=", 1)[0].strip():
            raise ValueError(f"dart-define 格式错误：{item!r}，应为 KEY=VALUE")
        result.append(f"--dart-define={item}")
    return result


def build_command(
    flutter: str,
    platform: str,
    target: str,
    mode: str,
    flavor: str = "",
    dart_defines: str = "",
    architecture: str = "arm64",
) -> list[str]:
    """Build a subprocess argument list without invoking a shell."""
    try:
        build_target = PLATFORM_TARGETS[platform][target]
    except KeyError as exc:
        raise ValueError(f"不支持的构建目标：{platform} / {target}") from exc

    mode = mode.lower().strip()
    if mode not in {"debug", "profile", "release"}:
        raise ValueError(f"不支持的构建模式：{mode}")

    command = [flutter, "build", build_target, f"--{mode}"]
    if platform == "Android" and target == "APK":
        if architecture not in APK_ARCHITECTURES:
            raise ValueError(f"不支持的 APK 架构：{architecture}")
        target_platform = APK_ARCHITECTURES[architecture]
        if target_platform:
            command.extend(["--target-platform", target_platform])
    flavor = flavor.strip()
    if flavor:
        command.extend(["--flavor", flavor])
    command.extend(parse_dart_defines(dart_defines))
    return command


def output_directory(platform: str, target: str, mode: str) -> Path:
    mode_name = mode.strip().capitalize()
    if platform == "Android" and target == "APK":
        return PROJECT_ROOT / "build/app/outputs/flutter-apk"
    if platform == "Android" and target == "AAB":
        return PROJECT_ROOT / "build/app/outputs/bundle"
    if platform == "macOS":
        return PROJECT_ROOT / f"build/macos/Build/Products/{mode_name}"
    if platform == "Windows":
        return PROJECT_ROOT / f"build/windows/x64/runner/{mode_name}"
    raise ValueError(f"不支持的输出目标：{platform} / {target}")


def load_config() -> dict:
    try:
        with CONFIG_PATH.open("r", encoding="utf-8") as config_file:
            data = json.load(config_file)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_config(values: dict) -> None:
    safe_values = {
        key: values[key]
        for key in ("platform", "target", "mode", "flavor", "dart_defines", "architecture")
        if key in values
    }
    try:
        CONFIG_PATH.write_text(
            json.dumps(safe_values, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    except OSError:
        # A read-only project should not prevent a build.
        pass


class PackagerApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Flutter 打包工具")
        self.root.geometry("820x650")
        self.root.minsize(680, 520)

        self.events: queue.Queue[tuple] = queue.Queue()
        self.process: Optional[subprocess.Popen] = None
        self.process_lock = threading.Lock()
        self.output_path: Optional[Path] = None
        self.closing = False

        config = load_config()
        self.platform_var = tk.StringVar(value=config.get("platform", "Android"))
        self.target_var = tk.StringVar(value=config.get("target", "APK"))
        self.mode_var = tk.StringVar(value=config.get("mode", "Release"))
        self.flavor_var = tk.StringVar(value=config.get("flavor", ""))
        self.dart_defines_var = tk.StringVar(value=config.get("dart_defines", ""))
        architecture = config.get("architecture", "arm64")
        self.architecture_var = tk.StringVar(
            value=architecture if architecture in APK_ARCHITECTURES else "arm64"
        )
        self.status_var = tk.StringVar(value="准备就绪")
        self.command_var = tk.StringVar(value="")

        self._build_ui()
        self._update_targets()
        self._check_environment()
        self.root.after(100, self._drain_events)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self) -> None:
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(2, weight=1)

        options = ttk.LabelFrame(self.root, text="构建配置", padding=12)
        options.grid(row=0, column=0, padx=12, pady=(12, 8), sticky="ew")
        for column in (1, 3):
            options.columnconfigure(column, weight=1)

        ttk.Label(options, text="平台").grid(row=0, column=0, padx=(0, 8), pady=5, sticky="w")
        self.platform_combo = ttk.Combobox(
            options,
            textvariable=self.platform_var,
            values=list(PLATFORM_TARGETS),
            state="readonly",
        )
        self.platform_combo.grid(row=0, column=1, padx=(0, 18), pady=5, sticky="ew")
        self.platform_combo.bind("<<ComboboxSelected>>", lambda _event: self._update_targets())

        ttk.Label(options, text="目标").grid(row=0, column=2, padx=(0, 8), pady=5, sticky="w")
        self.target_combo = ttk.Combobox(
            options, textvariable=self.target_var, state="readonly"
        )
        self.target_combo.grid(row=0, column=3, pady=5, sticky="ew")
        self.target_combo.bind("<<ComboboxSelected>>", lambda _event: self._update_targets())

        ttk.Label(options, text="模式").grid(row=1, column=0, padx=(0, 8), pady=5, sticky="w")
        self.mode_combo = ttk.Combobox(
            options,
            textvariable=self.mode_var,
            values=("Debug", "Profile", "Release"),
            state="readonly",
        )
        self.mode_combo.grid(row=1, column=1, padx=(0, 18), pady=5, sticky="ew")
        self.mode_combo.bind("<<ComboboxSelected>>", lambda _event: self._update_command_preview())

        ttk.Label(options, text="Flavor").grid(row=1, column=2, padx=(0, 8), pady=5, sticky="w")
        self.flavor_entry = ttk.Entry(options, textvariable=self.flavor_var)
        self.flavor_entry.grid(row=1, column=3, pady=5, sticky="ew")
        self.flavor_entry.bind("<KeyRelease>", lambda _event: self._update_command_preview())

        ttk.Label(options, text="Dart defines").grid(
            row=2, column=0, padx=(0, 8), pady=5, sticky="nw"
        )
        self.defines_entry = ttk.Entry(options, textvariable=self.dart_defines_var)
        self.defines_entry.grid(row=2, column=1, columnspan=3, pady=5, sticky="ew")
        self.defines_entry.bind("<KeyRelease>", lambda _event: self._update_command_preview())
        ttk.Label(options, text="多个值用逗号分隔，例如 APP_ENV=dev,API_URL=https://example.com").grid(
            row=3, column=1, columnspan=3, padx=(0, 18), sticky="w"
        )

        ttk.Label(options, text="APK 架构").grid(
            row=4, column=0, padx=(0, 8), pady=5, sticky="w"
        )
        self.architecture_combo = ttk.Combobox(
            options, textvariable=self.architecture_var,
            values=list(APK_ARCHITECTURES), state="readonly",
        )
        self.architecture_combo.grid(row=4, column=1, padx=(0, 18), pady=5, sticky="ew")
        self.architecture_combo.bind(
            "<<ComboboxSelected>>", lambda _event: self._update_command_preview()
        )

        command_frame = ttk.LabelFrame(self.root, text="命令预览", padding=(12, 6))
        command_frame.grid(row=1, column=0, padx=12, pady=(0, 8), sticky="ew")
        command_frame.columnconfigure(0, weight=1)
        ttk.Label(command_frame, textvariable=self.command_var, anchor="w").grid(
            row=0, column=0, sticky="ew"
        )

        log_frame = ttk.LabelFrame(self.root, text="构建日志", padding=8)
        log_frame.grid(row=2, column=0, padx=12, pady=(0, 8), sticky="nsew")
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        self.log_text = tk.Text(log_frame, wrap="none", state="disabled")
        self.log_text.grid(row=0, column=0, sticky="nsew")
        y_scroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log_text.yview)
        y_scroll.grid(row=0, column=1, sticky="ns")
        self.log_text.configure(yscrollcommand=y_scroll.set)

        footer = ttk.Frame(self.root, padding=(12, 0, 12, 12))
        footer.grid(row=3, column=0, sticky="ew")
        footer.columnconfigure(0, weight=1)
        ttk.Label(footer, textvariable=self.status_var).grid(row=0, column=0, sticky="w")
        self.open_button = ttk.Button(footer, text="打开输出目录", command=self._open_output)
        self.open_button.grid(row=0, column=1, padx=6)
        self.stop_button = ttk.Button(footer, text="停止", command=self._stop_build, state="disabled")
        self.stop_button.grid(row=0, column=2, padx=6)
        self.build_button = ttk.Button(footer, text="开始构建", command=self._start_build)
        self.build_button.grid(row=0, column=3)

        self._controls = [
            self.platform_combo,
            self.target_combo,
            self.mode_combo,
            self.flavor_entry,
            self.defines_entry,
            self.architecture_combo,
        ]

    def _update_targets(self) -> None:
        if self.platform_var.get() not in PLATFORM_TARGETS:
            self.platform_var.set("Android")
        targets = list(PLATFORM_TARGETS[self.platform_var.get()].keys())
        self.target_combo["values"] = targets
        if self.target_var.get() not in targets:
            self.target_var.set(targets[0])
        self.architecture_combo.configure(
            state="readonly" if self.platform_var.get() == "Android"
            and self.target_var.get() == "APK" else "disabled"
        )
        self._update_command_preview()

    def _update_command_preview(self) -> None:
        flutter = shutil.which("flutter") or "flutter"
        try:
            command = build_command(
                flutter,
                self.platform_var.get(),
                self.target_var.get(),
                self.mode_var.get(),
                self.flavor_var.get(),
                self.dart_defines_var.get(),
                self.architecture_var.get(),
            )
            self.command_var.set(" ".join(_quote_for_display(part) for part in command))
        except ValueError as error:
            self.command_var.set(str(error))

    def _check_environment(self) -> None:
        problems = []
        if not (PROJECT_ROOT / "pubspec.yaml").is_file():
            problems.append(f"找不到 Flutter 项目：{PROJECT_ROOT}")
        if shutil.which("flutter") is None:
            problems.append("找不到 flutter 命令，请先将 Flutter 加入 PATH。")
        if problems:
            self.status_var.set("环境检查失败")
            self._append_log("环境检查失败：\n- " + "\n- ".join(problems) + "\n")
            self.build_button.configure(state="disabled")
        else:
            self.status_var.set(f"环境就绪：{PROJECT_ROOT}")

    def _start_build(self) -> None:
        with self.process_lock:
            if self.process is not None:
                return
        try:
            flutter = shutil.which("flutter")
            if flutter is None:
                raise ValueError("找不到 flutter 命令，请先将 Flutter 加入 PATH。")
            command = build_command(
                flutter,
                self.platform_var.get(),
                self.target_var.get(),
                self.mode_var.get(),
                self.flavor_var.get(),
                self.dart_defines_var.get(),
                self.architecture_var.get(),
            )
        except ValueError as error:
            messagebox.showerror("无法开始构建", str(error))
            return

        save_config(
            {
                "platform": self.platform_var.get(),
                "target": self.target_var.get(),
                "mode": self.mode_var.get(),
                "flavor": self.flavor_var.get(),
                "dart_defines": self.dart_defines_var.get(),
                "architecture": self.architecture_var.get(),
            }
        )
        self.output_path = output_directory(
            self.platform_var.get(), self.target_var.get(), self.mode_var.get()
        )
        self._append_log(f"$ {self.command_var.get()}\n\n")
        self.status_var.set("构建中...")
        self.open_button.configure(state="disabled")
        self.build_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        for control in self._controls:
            control.configure(state="disabled")
        threading.Thread(target=self._run_process, args=(command,), daemon=True).start()

    def _run_process(self, command: list[str]) -> None:
        creation_flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        try:
            process = subprocess.Popen(
                command,
                cwd=PROJECT_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                creationflags=creation_flags,
                start_new_session=(os.name != "nt"),
            )
            with self.process_lock:
                self.process = process
            assert process.stdout is not None
            for line in process.stdout:
                self.events.put(("log", line))
            return_code = process.wait()
            self.events.put(("finished", return_code))
        except OSError as error:
            self.events.put(("error", str(error)))
        finally:
            with self.process_lock:
                self.process = None

    def _stop_build(self) -> None:
        with self.process_lock:
            process = self.process
        if process is None:
            return
        self.status_var.set("正在停止构建...")
        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            else:
                os.killpg(process.pid, signal.SIGTERM)
        except OSError as error:
            self._append_log(f"停止构建失败：{error}\n")

    def _drain_events(self) -> None:
        try:
            while True:
                event, value = self.events.get_nowait()
                if event == "log":
                    self._append_log(value)
                elif event == "finished":
                    self._finish_build(value)
                elif event == "error":
                    self._append_log(f"启动构建失败：{value}\n")
                    self._finish_build(1)
        except queue.Empty:
            pass
        if not self.closing:
            self.root.after(100, self._drain_events)

    def _finish_build(self, return_code: int) -> None:
        self.stop_button.configure(state="disabled")
        self.build_button.configure(state="normal")
        for control in self._controls:
            control.configure(state="readonly" if isinstance(control, ttk.Combobox) else "normal")
        self._update_targets()
        if return_code == 0:
            self.status_var.set(f"构建成功：{self.output_path}")
            if self.output_path and self.output_path.exists():
                self.open_button.configure(state="normal")
        elif self.status_var.get() == "正在停止构建...":
            self.status_var.set("构建已停止")
        else:
            self.status_var.set(f"构建失败（退出码 {return_code}）")

    def _append_log(self, text: str) -> None:
        self.log_text.configure(state="normal")
        self.log_text.insert("end", text)
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _open_output(self) -> None:
        if not self.output_path or not self.output_path.exists():
            messagebox.showinfo("输出目录", "输出目录暂不存在，请先成功完成一次构建。")
            return
        if sys.platform == "darwin":
            command = ["open", str(self.output_path)]
        elif os.name == "nt":
            command = ["explorer", str(self.output_path)]
        else:
            command = ["xdg-open", str(self.output_path)]
        subprocess.Popen(command)

    def _on_close(self) -> None:
        with self.process_lock:
            running = self.process is not None
        if running:
            if not messagebox.askyesno("正在构建", "构建仍在进行，确定要停止并退出吗？"):
                return
            self._stop_build()
        self.closing = True
        self.root.destroy()


def _quote_for_display(value: str) -> str:
    if any(character.isspace() for character in value) or '"' in value:
        return '"' + value.replace('"', '\\"') + '"'
    return value


def main() -> None:
    root = tk.Tk()
    PackagerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
