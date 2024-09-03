#include <catch2/catch_test_macros.hpp>
#include <NyuTestUtil.hpp>

#include <VAHBUart_tl.h>

using VAHBUart = VAHBUart_tl;

static void reset(VAHBUart& uart) {
  uart.rx = 1;
  uart.wen = 0;
  uart.ren = 0;
  nyu::reset(uart);
}

TEST_CASE("AHBUart, reset") {
  auto& uart {nyu::getDUT<VAHBUart>()};

  reset(uart);

  nyu::tick(uart, 50);

  REQUIRE(uart.tx == 1);
}
