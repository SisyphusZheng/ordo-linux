"""Run the backported status and shutdown branches with simulated SMC reads."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
def function(name):
    start = source.index(name)
    return source[start:source.index("\n}", start) + 2]

stubs = r"""
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
enum { BITV, B0AV, BCF0 };
#define SMC_KEY(key) key
struct apple_smc_key_info { int size; };
struct macsmc_power { int smc, dev; bool shutdown_started; };
struct work_struct { struct macsmc_power power; };
#define container_of(w,t,m) (&(w)->power)
#define dev_warn(...) ((void)0)
#define dev_err(...) ((void)0)
#define dev_crit(...) ((void)0)
static int width, value, voltage, calls, hard, read_error;
static int apple_smc_get_key_info(int s,int k,struct apple_smc_key_info *i){i->size=width; return 0;}
static int apple_smc_read_u32(int s,int k,u32 *v){assert(width==4); *v=value; return read_error;}
static int apple_smc_read_u8(int s,int k,u8 *v){assert(width==1); *v=value; return read_error;}
static int apple_smc_read_u16(int s,int k,u16 *v){*v=k==BITV?100:voltage; return 0;}
#define ssleep(t) ((void)0)
#define orderly_poweroff(force) (++calls)
#define kernel_can_power_off() true
#define kernel_power_off() (++hard)
#define kernel_restart(msg) (++hard)
"""
main = r"""
int main(void) {
    struct work_struct w = {0};
    voltage = 120;
    for (width=1; width<=4; width*=2) {
        for (value=0; value<=1; value++) {
            for (read_error=-1; read_error<=0; read_error++) {
                calls=0; w.power.shutdown_started=false;
                macsmc_power_critical_work(&w);
                assert(calls==(value && width!=2 && !read_error)); assert(!hard);
            }
        }
    }
    voltage=90; macsmc_power_critical_work(&w); assert(hard==1);
}
"""
with tempfile.TemporaryDirectory() as d:
    path = Path(d)
    test = path / 'driver.c'
    test.write_text(stubs + function('static int macsmc_read_empty_flag') +
                    function('static void macsmc_power_critical_work') + main)
    subprocess.run(['cc', test, '-o', path/'test'], check=True)
    subprocess.run([path/'test'], check=True)
