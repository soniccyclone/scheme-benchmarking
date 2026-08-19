/* Does rsqrt+Newton beat sqrt+divide for d^-1.5 SCALAR, and on LATENCY?

   D37 answered a different question and answered it correctly: at 256 bits,
   with independent chains, approximating loses (2.371 cyc/lane against 2.042).
   Two things about that do not transfer to nbody's inner loop.

   It ran PACKED at 256 bits, where the divider costs about two cycles a lane.
   The loop emits vdivsd and sqrtsd -- SCALAR, five cycles of divider occupancy
   each (llvm-mca, D90).

   And it measured THROUGHPUT, deliberately, using four independent chains. But
   llvm-mca puts the loop at 85.65% register dependencies (D90), so the quantity
   that decides is LATENCY: how long the serial chain is, not how many can be in
   flight. A form can lose on throughput and win on latency -- rsqrt+Newton is
   exactly that shape, trading one long divider op for several short multiplies.

   So: both forms, both axes, scalar. LAT feeds each result into the next; TPT
   runs four independent chains. */
#include <stdio.h>
#include <immintrin.h>
#include <math.h>
#define N 4000000
#define TSC(v){unsigned lo,hi;__asm__ __volatile__("lfence;rdtsc":"=a"(lo),"=d"(hi));v=((unsigned long long)hi<<32)|lo;}
volatile double sink;

static inline double approx_n(double d,int steps){
  __m128 f = _mm_set_ss((float)d);
  double y = (double)_mm_cvtss_f32(_mm_rsqrt_ss(f));
  double h = 0.5*d;
  for(int s=0;s<steps;s++) y = y*(1.5 - h*y*y);
  return y*y*y;
}
static inline double approx_pow_m15(double d){
  /* y ~ d^-0.5 by rsqrt on floats, refined in double; d^-1.5 = y^3 */
  __m128 f = _mm_set_ss((float)d);
  double y = (double)_mm_cvtss_f32(_mm_rsqrt_ss(f));
  double h = 0.5*d;
  y = y*(1.5 - h*y*y);
  y = y*(1.5 - h*y*y);
  y = y*(1.5 - h*y*y);
  return y*y*y;
}
static inline double exact_pow_m15(double d){ return 1.0/(d*sqrt(d)); }

int main(void){
  unsigned long long c0,c1; double v,w[4];

  v=1.5; TSC(c0);
  for(int i=0;i<N;i++) v = exact_pow_m15(v) + 1.5;
  TSC(c1); sink=v;
  printf("  exact  sqrt+div  LATENCY  %7.3f cyc/op\n",(double)(c1-c0)/N);

  v=1.5; TSC(c0);
  for(int i=0;i<N;i++) v = approx_pow_m15(v) + 1.5;
  TSC(c1); sink=v;
  printf("  rsqrt+3 Newton   LATENCY  %7.3f cyc/op\n",(double)(c1-c0)/N);

  for(int k=0;k<4;k++) w[k]=k+1.5;
  TSC(c0);
  for(int i=0;i<N;i++) for(int k=0;k<4;k++) w[k]=exact_pow_m15(w[k])+1.5;
  TSC(c1); for(int k=0;k<4;k++) sink=w[k];
  printf("  exact  sqrt+div  THROUGHPUT %5.3f cyc/op\n",(double)(c1-c0)/((double)N*4));

  for(int k=0;k<4;k++) w[k]=k+1.5;
  TSC(c0);
  for(int i=0;i<N;i++) for(int k=0;k<4;k++) w[k]=approx_pow_m15(w[k])+1.5;
  TSC(c1); for(int k=0;k<4;k++) sink=w[k];
  printf("  rsqrt+3 Newton   THROUGHPUT %5.3f cyc/op\n",(double)(c1-c0)/((double)N*4));

  /* Fewer Newton steps: shorter chain, larger error. If ANY configuration beats
     the exact form on latency it is this one, so it is measured rather than
     assumed away. */
  for(int st=1;st<=3;st++){
    v=1.5; TSC(c0);
    for(int i=0;i<N;i++) v = approx_n(v,st) + 1.5;
    TSC(c1); sink=v;
    double e2=0.0;
    for(int i=1;i<=200000;i++){ double d=i*0.001;
      double e=exact_pow_m15(d), a=approx_n(d,st);
      double rel=(a-e)/e; if(rel<0)rel=-rel; if(rel>e2)e2=rel; }
    printf("  rsqrt+%d Newton   LATENCY  %7.3f cyc/op   worst rel err %.2e\n",
           st,(double)(c1-c0)/N,e2);
  }

  /* And what the approximation COSTS, since that is the other half of the
     decision and D24 is why this project does not trade it away silently. */
  double worst=0.0;
  for(int i=1;i<=200000;i++){ double d=i*0.001;
    double e=exact_pow_m15(d), a=approx_pow_m15(d);
    double rel=(a-e)/e; if(rel<0)rel=-rel; if(rel>worst)worst=rel; }
  printf("  worst relative error over d in [0.001,200]: %.3e\n",worst);
  return 0;
}
