#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    const unsigned char secret_encoded[] = {0x08, 0x13, 0x14, 0x1d, 0x0d, 0x13, 0x14, 0x05, 0x1e, 0x15, 0x14, 0x0e, 0x1e, 0x0f, 0x17, 0x0a, 0x05, 0x09, 0x1f, 0x19, 0x08, 0x1f, 0x0e, 0x05, 0x63, 0x3c, 0x69, 0x6a};
    const unsigned char control_encoded[] = {0x08, 0x13, 0x14, 0x1d, 0x0d, 0x13, 0x14, 0x05, 0x19, 0x15, 0x08, 0x1f, 0x05, 0x19, 0x15, 0x14, 0x0e, 0x08, 0x15, 0x16, 0x05, 0x6c, 0x3b, 0x68, 0x6b};
    volatile unsigned char mask = 0x5a;
    const size_t size = (size_t)sysconf(_SC_PAGESIZE);
    char *secret = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    char *control = malloc(size);
    if (secret == MAP_FAILED || control == NULL || mlock(secret, size) != 0 || madvise(secret, size, MADV_DONTDUMP) != 0)
        return 1;
    for (size_t i = 0; i < sizeof(secret_encoded); ++i) secret[i] = (char)(secret_encoded[i] ^ mask);
    for (size_t i = 0; i < sizeof(control_encoded); ++i) control[i] = (char)(control_encoded[i] ^ mask);
    if (mprotect(secret, size, PROT_READ) != 0) return 2;
    printf("pid=%ld control_len=%zu\n", (long)getpid(), sizeof(control_encoded));
    fflush(stdout);
    sleep(20);
    abort();
}
