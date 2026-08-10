#include <stdio.h>
#include <immintrin.h>
#define N 8000000
#define TSC(v){unsigned lo,hi;__asm__ __volatile__("lfence;rdtsc":"=a"(lo),"=d"(hi));v=((unsigned long long)hi<<32)|lo;}
volatile double sink;
int main(void){
  unsigned long long c0,c1;
  { double u[8]; for(int k=0;k<8;k++)u[k]=k+1.5;
    TSC(c0); for(int i=0;i<N;i++){ for(int k=0;k<8;k++) u[k]=1.0/__builtin_sqrt(u[k])+1.5; } TSC(c1);
    for(int k=0;k<8;k++)sink=u[k];
    printf("  scalar   %6.3f cyc per sqrt+div-lane  (8 chains)\n",(double)(c1-c0)/((double)N*8)); }
  { __m128d v[4]; for(int k=0;k<4;k++)v[k]=_mm_set1_pd(k+1.5); __m128d o=_mm_set1_pd(1.0),a=_mm_set1_pd(1.5);
    TSC(c0); for(int i=0;i<N;i++){ for(int k=0;k<4;k++) v[k]=_mm_add_pd(_mm_div_pd(o,_mm_sqrt_pd(v[k])),a); } TSC(c1);
    for(int k=0;k<4;k++)sink=_mm_cvtsd_f64(v[k]);
    printf("  128-bit  %6.3f cyc per sqrt+div-lane  (4 chains x 2)\n",(double)(c1-c0)/((double)N*8)); }
  { __m256d v[4]; for(int k=0;k<4;k++)v[k]=_mm256_set1_pd(k+1.5); __m256d o=_mm256_set1_pd(1.0),a=_mm256_set1_pd(1.5);
    TSC(c0); for(int i=0;i<N;i++){ for(int k=0;k<4;k++) v[k]=_mm256_add_pd(_mm256_div_pd(o,_mm256_sqrt_pd(v[k])),a); } TSC(c1);
    for(int k=0;k<4;k++)sink=_mm256_cvtsd_f64(v[k]);
    printf("  256-bit  %6.3f cyc per sqrt+div-lane  (4 chains x 4)\n",(double)(c1-c0)/((double)N*16)); }
  return 0;
}
