#include <stdio.h>
#include <unistd.h>
#include <time.h>

#include "bdbmpcie.h"
#include "dmasplitter.h"

static const uint32_t matrixSize = 4;
static const uint32_t matrixNumber = 200000;
/* static const uint32_t matrixNumber = 500*500*500; */
static const uint32_t compressedBit = 64 * 16;
static const uint32_t noiseMargin = 20;

int main(int argc, char** argv) {
    FILE* fin = fopen("matrix.bin", "rb");
    uint32_t *originMatrix = NULL;
    uint32_t *decompMatrix = NULL;
    size_t buffersize = 0;
    size_t datasize = 0;

    datasize = matrixNumber * matrixSize;
    originMatrix = (uint32_t *)malloc(sizeof(double) * datasize * 2);

    /* read bin matrix data */
    buffersize = fread(originMatrix, sizeof(uint32_t), (size_t)datasize * 2, fin);

    /* get pcie instance */
    BdbmPcie* pcie = BdbmPcie::getInstance();

    /* put noise Margin */
    pcie->userWriteWord(0, noiseMargin);

    /* put matrix number */
    pcie->userWriteWord(4, matrixNumber);

    /* put matrix data */
    for (int i = 0; i < matrixNumber * 2 * 4; i++) {
        pcie->userWriteWord(12, originMatrix[i]);
    }

    return 0;
}
