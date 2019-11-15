#include <stdio.h>
#include <stdlib.h>

#define SIZE 20000

int main(void)
{
    double *origin = (double *)malloc(sizeof(double)* SIZE * 4);
    double *result = (double *)malloc(sizeof(double)* SIZE * 4);

    FILE *ori;
    ori = fopen("matrix.bin","rb");
    fread(origin,sizeof(double),SIZE * 4,ori);

    FILE *res;
    res = fopen("result.bin","rb");
    fread(result,sizeof(double),SIZE * 4,res);
    int cnt = 0;

    for (int i = 0;  i < SIZE * 4; ++i) {
        double diff;
        if (origin[i] > result[i]) {
            diff = origin[i] - result[i];
        } else {
            diff = result[i] - origin[i];
        }

        if (diff > 0.001) {
            cnt++;
            printf("no!! origin %lf decomp %lf diff %lf \n",origin[i],result[i],diff);
        } else {
            /* printf("ya %lf %lf\n",origin[i],result[i]); */
        }
        if (origin[i] != result[i]) {
            printf("data is different %lf %lf\n",origin[i],result[i]);
        }
    }
    printf("\n---------\ncnt is %d",cnt);

    return 0;
}

