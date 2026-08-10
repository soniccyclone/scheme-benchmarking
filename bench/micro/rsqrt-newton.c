/* How much divider occupancy does an rsqrt+Newton form actually remove?
   nbody wants dt/(d2*sqrt(d2)) = dt * d2^-1.5. Exact form is sqrt then
   divide: two divider ops. The approximate form is one vrsqrtps and
   Newton refinement, which uses the multiplier instead. */
#include <stdio.h>
#include <immintrin.h>
#define N 8000000
#define TSC(v){unsigned lo,hi;__asm__ __volatile__("lfence;rdtsc":"=a"(lo),"=d"(hi));v=((unsigned long long)hi<<32)|lo;}
volatile double sink;
int main(void){
  unsigned long long c0,c1;
  __m256d v[4]; __m256d o=_mm256_set1_pd(1.0),a=_mm256_set1_pd(1.5);
  for(int k=0;k<4;k++)v[k]=_mm256_set1_pd(k+1.5);
  TSC(c0); for(int i=0;i<N;i++) for(int k=0;k<4;k++){ __m256d d=v[k];
      v[k]=_mm256_add_pd(_mm256_div_pd(o,_mm256_mul_pd(d,_mm256_sqrt_pd(d))),a); } TSC(c1);
  for(int k=0;k<4;k++)sink=_mm256_cvtsd_f64(v[k]);
  printf("  exact  sqrt+div, 256b   %6.3f cyc/lane\n",(double)(c1-c0)/((double)N*16));

  for(int k=0;k<4;k++)v[k]=_mm256_set1_pd(k+1.5);
  TSC(c0); for(int i=0;i<N;i++) for(int k=0;k<4;k++){ __m256d d=v[k];
      /* rsqrt on floats, two Newton steps in double: y ~ 1/sqrt(d) */
      __m128 f=_mm256_cvtpd_ps(d);
      __m256d y=_mm256_cvtps_pd(_mm_rsqrt_ps(f));
      __m256d h=_mm256_mul_pd(_mm256_set1_pd(0.5),d);
      y=_mm256_mul_pd(y,_mm256_sub_pd(_mm256_set1_pd(1.5),_mm256_mul_pd(h,_mm256_mul_pd(y,y))));
      y=_mm256_mul_pd(y,_mm256_sub_pd(_mm256_set1_pd(1.5),_mm256_mul_pd(h,_mm256_mul_pd(y,y))));
      y=_mm256_mul_pd(y,_mm256_sub_pd(_mm256_set1_pd(1.5),_mm256_mul_pd(h,_mm256_mul_pd(y,y))));
      /* d^-1.5 = y^3 */
      v[k]=_mm256_add_pd(_mm256_mul_pd(y,_mm256_mul_pd(y,y)),a); } TSC(c1);
  for(int k=0;k<4;k++)sink=_mm256_cvtsd_f64(v[k]);
  printf("  rsqrt+3 Newton, 256b   %6.3f cyc/lane\n",(double)(c1-c0)/((double)N*16));
  return 0;
}
