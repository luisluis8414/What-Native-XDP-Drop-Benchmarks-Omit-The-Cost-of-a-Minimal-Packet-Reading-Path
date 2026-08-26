#include <errno.h>
#include <linux/bpf.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static int sys_bpf(enum bpf_cmd cmd, union bpf_attr *attr)
{
    return syscall(__NR_bpf, cmd, attr, sizeof(*attr));
}

int main(int argc, char **argv)
{
    struct bpf_prog_info info = {};
    struct bpf_prog_info image_info = {};
    union bpf_attr attr = {};
    unsigned int info_len = sizeof(info);
    unsigned int prog_id;
    unsigned char *image;
    FILE *output;
    int fd;

    if (argc != 3) {
        fprintf(stderr, "usage: %s PROG_ID OUTPUT\n", argv[0]);
        return 2;
    }

    prog_id = strtoul(argv[1], NULL, 10);
    attr.prog_id = prog_id;
    fd = sys_bpf(BPF_PROG_GET_FD_BY_ID, &attr);
    if (fd < 0) {
        fprintf(stderr, "BPF_PROG_GET_FD_BY_ID: %s\n", strerror(errno));
        return 1;
    }

    memset(&attr, 0, sizeof(attr));
    attr.info.bpf_fd = fd;
    attr.info.info_len = info_len;
    attr.info.info = (uintptr_t)&info;
    if (sys_bpf(BPF_OBJ_GET_INFO_BY_FD, &attr)) {
        fprintf(stderr, "BPF_OBJ_GET_INFO_BY_FD length query: %s\n",
                strerror(errno));
        return 1;
    }

    image = calloc(1, info.jited_prog_len);
    if (!image) {
        fprintf(stderr, "calloc: %s\n", strerror(errno));
        return 1;
    }

    image_info.jited_prog_len = info.jited_prog_len;
    image_info.jited_prog_insns = (uintptr_t)image;
    memset(&attr, 0, sizeof(attr));
    attr.info.bpf_fd = fd;
    attr.info.info_len = info_len;
    attr.info.info = (uintptr_t)&image_info;
    if (sys_bpf(BPF_OBJ_GET_INFO_BY_FD, &attr)) {
        fprintf(stderr, "BPF_OBJ_GET_INFO_BY_FD image query: %s\n",
                strerror(errno));
        return 1;
    }

    output = fopen(argv[2], "wb");
    if (!output) {
        fprintf(stderr, "fopen: %s\n", strerror(errno));
        return 1;
    }
    if (fwrite(image, 1, image_info.jited_prog_len, output) !=
        image_info.jited_prog_len) {
        fprintf(stderr, "fwrite: %s\n", strerror(errno));
        return 1;
    }
    fclose(output);
    fprintf(stderr, "program %u: wrote %u JIT bytes to %s\n",
            prog_id, image_info.jited_prog_len, argv[2]);
    return 0;
}

