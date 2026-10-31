#!/usr/bin/env bash
set -euo pipefail
nes_launch_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
nes_launch_work="$(cd -- "$nes_launch_repo/.." && pwd)/work/snes-compatibility-launch"
mkdir -p "$nes_launch_work"
cd -- "$nes_launch_repo"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/test_transitions.c -o "$nes_launch_work/test-transitions"
"$nes_launch_work/test-transitions"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/arguments.c tools/snes-compatibility-launch/test_arguments.c \
  -o "$nes_launch_work/test-arguments"
"$nes_launch_work/test-arguments"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/isolated_saves.c tools/snes-compatibility-launch/test_isolated_saves.c \
  -o "$nes_launch_work/test-isolated-saves"
"$nes_launch_work/test-isolated-saves"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/test_control_pipe.c \
  -o "$nes_launch_work/test-control-pipe"
"$nes_launch_work/test-control-pipe"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/owned_directory.c tools/snes-compatibility-launch/test_owned_directory.c \
  -o "$nes_launch_work/test-owned-directory"
"$nes_launch_work/test-owned-directory"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/owned_directory.c tools/snes-compatibility-launch/test_owned_file.c \
  -o "$nes_launch_work/test-owned-file"
"$nes_launch_work/test-owned-file"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/owned_directory.c tools/snes-compatibility-launch/test_checkpoint_workspace.c \
  -o "$nes_launch_work/test-checkpoint-workspace"
"$nes_launch_work/test-checkpoint-workspace"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/shutdown_gate.c tools/snes-compatibility-launch/test_shutdown_gate.c \
  -o "$nes_launch_work/test-shutdown-gate"
"$nes_launch_work/test-shutdown-gate"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/autosave_watch.c tools/snes-compatibility-launch/test_autosave_watch.c \
  -o "$nes_launch_work/test-autosave-watch"
"$nes_launch_work/test-autosave-watch"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/autosave_verify.c tools/snes-compatibility-launch/test_autosave_verify.c \
  -o "$nes_launch_work/test-autosave-verify"
"$nes_launch_work/test-autosave-verify"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/autosave_publish.c tools/snes-compatibility-launch/owned_directory.c \
  tools/snes-compatibility-launch/test_autosave_publish.c -o "$nes_launch_work/test-autosave-publish"
"$nes_launch_work/test-autosave-publish"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -DHC_AUTOSAVE_TEST_AFTER_RENAME \
  tools/snes-compatibility-launch/autosave_publish.c tools/snes-compatibility-launch/owned_directory.c \
  tools/snes-compatibility-launch/test_autosave_post_publish.c -o "$nes_launch_work/test-autosave-post-publish"
"$nes_launch_work/test-autosave-post-publish"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/autosave_target.c tools/snes-compatibility-launch/autosave_publish.c \
  tools/snes-compatibility-launch/owned_directory.c tools/snes-compatibility-launch/test_autosave_target.c \
  -o "$nes_launch_work/test-autosave-target"
"$nes_launch_work/test-autosave-target"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/autosave_target.c tools/snes-compatibility-launch/autosave_publish.c \
  tools/snes-compatibility-launch/owned_directory.c tools/snes-compatibility-launch/test_autosave_prepare.c \
  -o "$nes_launch_work/test-autosave-prepare"
"$nes_launch_work/test-autosave-prepare"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -pthread \
  tools/snes-compatibility-launch/admission_barrier.c tools/snes-compatibility-launch/test_admission_barrier.c \
  -o "$nes_launch_work/test-admission-barrier"
"$nes_launch_work/test-admission-barrier"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -DHC_CORE_TEST_INJECT \
  -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
  tools/snes-compatibility-launch/core_deletion.c tools/snes-compatibility-launch/test_core_deletion.c \
  vendor/mbedtls/library/sha256.c vendor/mbedtls/library/platform_util.c \
  -o "$nes_launch_work/test-core-deletion"
"$nes_launch_work/test-core-deletion"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/child_process.c \
  tools/snes-compatibility-launch/control_command.c tools/snes-compatibility-launch/checkpoint_receipt.c tools/snes-compatibility-launch/screenshot_png.c tools/snes-compatibility-launch/test_child_process.c -lz -o "$nes_launch_work/test-child-process"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/child_process.c \
  tools/snes-compatibility-launch/test_child_verified.c -o "$nes_launch_work/test-child-verified"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/child_process.c \
  tools/snes-compatibility-launch/test_child_confirmed.c -o "$nes_launch_work/test-child-confirmed"
"$nes_launch_work/test-child-confirmed"
"$nes_launch_work/test-child-verified"
"$nes_launch_work/test-child-process"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Dwaitpid=hc_test_waitpid \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/child_process.c \
  tools/snes-compatibility-launch/test_child_wait_interruption.c -o "$nes_launch_work/test-child-wait-interruption"
"$nes_launch_work/test-child-wait-interruption"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/control_command.c \
  tools/snes-compatibility-launch/test_control_command.c -o "$nes_launch_work/test-control-command"
"$nes_launch_work/test-control-command"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/screenshot_png.c tools/snes-compatibility-launch/test_screenshot_png.c \
  -lz -o "$nes_launch_work/test-screenshot-png"
"$nes_launch_work/test-screenshot-png"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/control_command.c \
  tools/snes-compatibility-launch/checkpoint_receipt.c tools/snes-compatibility-launch/screenshot_png.c tools/snes-compatibility-launch/test_checkpoint_receipt.c -lz \
  -o "$nes_launch_work/test-checkpoint-receipt"
"$nes_launch_work/test-checkpoint-receipt"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/control_command.c \
  tools/snes-compatibility-launch/checkpoint_receipt.c tools/snes-compatibility-launch/screenshot_png.c \
  tools/snes-compatibility-launch/screenshot_completion.c tools/snes-compatibility-launch/test_screenshot_completion.c \
  -lz -o "$nes_launch_work/test-screenshot-completion"
"$nes_launch_work/test-screenshot-completion"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/control_command.c \
  tools/snes-compatibility-launch/checkpoint_receipt.c tools/snes-compatibility-launch/screenshot_png.c \
  tools/snes-compatibility-launch/save_completion.c tools/snes-compatibility-launch/test_save_completion.c \
  -lz -o "$nes_launch_work/test-save-completion"
"$nes_launch_work/test-save-completion"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/control_command.c \
  tools/snes-compatibility-launch/test_threaded_signal.c -pthread -o "$nes_launch_work/test-threaded-signal"
"$nes_launch_work/test-threaded-signal"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/snes-compatibility-launch/control_pipe.c tools/snes-compatibility-launch/control_command.c \
  tools/snes-compatibility-launch/checkpoint_receipt.c tools/snes-compatibility-launch/screenshot_png.c \
  tools/snes-compatibility-launch/save_completion.c tools/snes-compatibility-launch/screenshot_completion.c \
  tools/snes-compatibility-launch/runtime_checkpoint.c tools/snes-compatibility-launch/test_runtime_checkpoint.c \
  -lz -o "$nes_launch_work/test-runtime-checkpoint"
"$nes_launch_work/test-runtime-checkpoint"
if [[ -n "${HAKCHI_ARM_CC:-}" ]]; then
  for nes_launch_component in transitions arguments isolated_saves control_pipe owned_directory child_process control_command screenshot_png checkpoint_receipt screenshot_completion save_completion runtime_checkpoint shutdown_gate autosave_watch autosave_verify autosave_publish autosave_target admission_barrier core_deletion; do
    "$HAKCHI_ARM_CC" -std=c11 -Wall -Wextra -Werror -O2 -Ivendor/mbedtls/include -c \
      "tools/snes-compatibility-launch/$nes_launch_component.c" \
      -o "$nes_launch_work/$nes_launch_component.arm.o"
  done
  printf 'ARM components cross-compiled as inert objects; no console execution.\n'
fi
