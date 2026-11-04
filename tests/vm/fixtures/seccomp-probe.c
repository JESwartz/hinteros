/* Inside the app sandbox (VM test sandbox): one `<check>=yes|no` line per system call check.
 * "yes" means the sandbox behaves as designed: blocked calls fail with the filter's errno (not
 * the errno the kernel gives without the filter; io_uring and x32 are the exceptions, see
 * sandbox.nix), nested sandboxes still work. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/personality.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static void check(const char *name, int ok) { printf("%s=%s\n", name, ok ? "yes" : "no"); }

/* The call failed with exactly `want`. */
static int fails(long r, int want) { return r == -1 && errno == want; }

/* Run `f` in a child; its exit status (0 = yes), or -signal when killed. */
static int in_child(int (*f)(void)) {
  pid_t pid = fork();
  if (pid == 0) _exit(f());
  int st;
  if (waitpid(pid, &st, 0) < 0) return 99;
  return WIFSIGNALED(st) ? -WTERMSIG(st) : WEXITSTATUS(st);
}

/* i386 getpid (int 0x80, eax 20): the filter kills the process. */
static int i386_call(void) {
  long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(20L) : "memory");
  return 0;
}

/* A user namespace with its own mount namespace, and a mount in it (nested sandboxes). */
static int userns_mount(void) {
  if (unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0) return 1;
  if (mount("none", "/tmp", "tmpfs", 0, NULL) != 0) return 2;
  return 0;
}

/* AF_PACKET in our own user and network namespace: the filter refuses the family. */
static int packet_in_userns(void) {
  if (unshare(CLONE_NEWUSER | CLONE_NEWNET) != 0) return 3;
  int fd = socket(AF_PACKET, SOCK_RAW, 0);
  return (fd < 0 && errno == EAFNOSUPPORT) ? 0 : 1;
}

int main(void) {
  int null = open("/dev/null", O_RDWR);
  /* KEYCTL_GET_KEYRING_ID (0), KEY_SPEC_SESSION_KEYRING (-3). */
  check("keyctl_blocked", fails(syscall(SYS_keyctl, 0, -3, 0), EPERM));
  check("add_key_blocked", fails(syscall(SYS_add_key, "user", "x", "y", 1, -3), EPERM));
  check("io_uring_blocked", fails(syscall(SYS_io_uring_setup, 1, NULL), EPERM));
  /* Without the filter: ENOTTY (/dev/null is no terminal). */
  check("tiocsti_blocked", fails(ioctl(null, TIOCSTI, "x"), EPERM));
  check("tioclinux_blocked", fails(ioctl(null, TIOCLINUX, "x"), EPERM));
  /* UFFD_USER_MODE_ONLY: allowed for users without the filter. */
  check("userfaultfd_blocked", fails(syscall(SYS_userfaultfd, 1), EPERM));
  /* Without the filter: EFAULT (the kernel reads the NULL attr before any permission check). */
  check("perf_blocked", fails(syscall(SYS_perf_event_open, NULL, 0, -1, -1, 0), EPERM));
  /* Without the filter: EPERM (no CAP_SYS_ADMIN here). */
  check("fsopen_blocked", fails(syscall(SYS_fsopen, "tmpfs", 0), ENOSYS));
  check("no_randomize_blocked", fails(personality(ADDR_NO_RANDOMIZE), EPERM));
  check("personality_query", personality(0xffffffff) != -1);
  check("x32_blocked", fails(syscall(0x40000000 | SYS_getpid), ENOSYS));
  check("i386_killed", in_child(i386_call) == -SIGSYS);
  check("packet_blocked", in_child(packet_in_userns) == 0);
  check("userns", in_child(userns_mount) == 0);
  return 0;
}
