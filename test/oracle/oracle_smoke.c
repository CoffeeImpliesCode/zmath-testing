#include <flint/arb.h>
#include <mpfr.h>

int zmath_testing_mpfr_smoke(void) {
    mpfr_t value;
    mpfr_init2(value, 128);
    mpfr_const_pi(value, MPFR_RNDN);
    const int ok = mpfr_cmp_ui(value, 3) > 0;
    mpfr_clear(value);
    return ok;
}

int zmath_testing_arb_smoke(void) {
    arb_t value;
    arb_init(value);
    arb_const_pi(value, 128);
    const int ok = !arb_is_zero(value);
    arb_clear(value);
    return ok;
}
