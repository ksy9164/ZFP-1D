#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>

#include "bdbmpcie.h"
#include "dmasplitter.h"

static const uint32_t matrixSize = 4;
static const uint32_t matrixNumber = 20000;
/* static const uint32_t matrixNumber = 500*500*500; */
static const uint32_t compressedBit = 64 * 16;
static const uint32_t noiseMargin = 20;

void *send_data (void *origin)
{
    uint32_t *originMatrix = (uint32_t *)origin;
    BdbmPcie* pcie = BdbmPcie::getInstance();
    for (int i = 0; i < matrixNumber * 2 * 4; i++) {
        pcie->userWriteWord(12, originMatrix[i]);
    }
}

void *get_data (void *decomp)
{
    uint32_t *decompMatrix = (uint32_t *)decomp;
    BdbmPcie* pcie = BdbmPcie::getInstance();
    for (int i = 0;  i < matrixNumber * 2 * 4; ++i) {
        uint32_t getd = pcie->userReadWord(0);
        decompMatrix[i] = getd;
    }
}
int main(int argc, char** argv) {
    FILE* fin = fopen("matrix.bin", "rb");
    uint32_t *originMatrix = NULL;
    uint32_t *decompMatrix = NULL;
    size_t buffersize = 0;
    int status;

    originMatrix = (uint32_t *)malloc(sizeof(double) * matrixNumber * 4 * 2);
    decompMatrix = (uint32_t *)malloc(sizeof(double) * matrixNumber * 4 * 2);

    /* read bin matrix data */
    buffersize = fread(originMatrix, sizeof(uint32_t), (size_t)matrixNumber * 4  * 2, fin);

    /* get pcie instance */
    BdbmPcie* pcie = BdbmPcie::getInstance();

    /* put noise Margin */
    pcie->userWriteWord(0, noiseMargin);

    /* put matrix number */
    pcie->userWriteWord(4, matrixNumber);

    for (int i = 0; i < matrixNumber * 2 * 4; i++) {
        pcie->userWriteWord(12, originMatrix[i]);
    }

    for (int i = 0;  i < matrixNumber * 2 * 4 - 40; ++i) {
        uint32_t getd = pcie->userReadWord(0);
        decompMatrix[i] = getd;
    }

    FILE* out = fopen("result.bin", "wb");
    fwrite(decompMatrix, sizeof(double), matrixNumber * 4, out);

    /* put matrix data */
/*     pthread_t p_thread[2];
 *     pthread_create(&p_thread[0],NULL,send_data,(void *)originMatrix);
 *     pthread_create(&p_thread[1],NULL,get_data,(void *)decompMatrix);
 *
 *     pthread_join(p_thread[0],(void **)&status);
 *     pthread_join(p_thread[1],(void **)&status); */
    return 0;
}
