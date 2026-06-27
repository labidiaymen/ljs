// A tiny C++ library exposed to Lumen through a C ABI (extern "C").
#include <cmath>

extern "C" int rectangle_area(int w, int h) {
    return w * h;
}

extern "C" double circle_area(double r) {
    return 3.14159265358979 * r * r;
}
