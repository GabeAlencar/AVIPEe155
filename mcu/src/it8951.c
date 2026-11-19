// it8951.c
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// IT8951 e-paper controller over SPI. Sources: the IT8951 I80/SPI
// programming guide and Waveshare's IT8951 example code.
//
// Every SPI transaction is CS low, a 16-bit preamble, then 16-bit words:
//   0x6000 command, 0x0000 write data, 0x1000 read data (one dummy word first)
// HRDY must be high before the preamble and before the data that follows it.
//
// The image is sent in 1-bpp mode: each byte holds 8 pixels and is loaded
// as one 8-bpp "pixel", so the load area is IMG_W / 8 wide. A display command
// with bit 18 of UP1SR set then reads the buffer as 1 bit per pixel, using
// BGVR for the two gray levels.

#include <string.h>
#include "STM32L432KC.h"
#include "config.h"
#include "it8951.h"
#include "timing.h"

// ---- commands ----
#define CMD_SYS_RUN        0x0001
#define CMD_REG_RD         0x0010
#define CMD_REG_WR         0x0011
#define CMD_LD_IMG_AREA    0x0021
#define CMD_LD_IMG_END     0x0022
#define CMD_DPY_BUF_AREA   0x0037
#define CMD_VCOM           0x0039
#define CMD_GET_DEV_INFO   0x0302

// ---- registers ----
#define REG_I80CPCR        0x0004   // packed write enable
#define REG_LISAR          0x0208   // image load address, low 16 bits (+2: high)
#define REG_UP1SR          0x1138   // +2 holds bit 18 (1-bpp mode) as bit 2
#define REG_LUTAFSR        0x1224   // nonzero while a display update runs
#define REG_BGVR           0x1250   // 1-bpp colors: {bit=1 gray, bit=0 gray}

#define PIX_8BPP           3
#define ENDIAN_LITTLE      0

#define GRAY_BLACK         0x00
#define GRAY_WHITE         0xF0

#define HRDY_TIMEOUT_US    3000000

static uint32_t img_addr;
static int      timed_out;

// ---- low level ----

static void pin_af(int pin, int af) {
    GPIO_TypeDef *port = gpioPinToBase(pin);
    int n = gpioPinOffset(pin);
    pinMode(pin, GPIO_ALT);
    port->AFR[n >> 3] &= ~(0xFu << (4 * (n & 7)));
    port->AFR[n >> 3] |= (uint32_t)af << (4 * (n & 7));
    port->OSPEEDR |= 3u << (2 * n);
}

static void spi_init(void) {
    gpioEnable(GPIO_PORT_A);
    gpioEnable(GPIO_PORT_B);
    RCC->APB2ENR |= RCC_APB2ENR_SPI1EN;
    RCC->AHB1ENR |= RCC_AHB1ENR_DMA1EN;

    pin_af(EPD_SCK, 5);
    pin_af(EPD_MISO, 5);
    pin_af(EPD_MOSI, 5);

    digitalWrite(EPD_CS, 1);
    pinMode(EPD_CS, GPIO_OUTPUT);
    digitalWrite(EPD_RST, 1);
    pinMode(EPD_RST, GPIO_OUTPUT);
    pinMode(EPD_HRDY, GPIO_INPUT);

    // master, mode 0, MSB first, software NSS held high, 16-bit words
    SPI1->CR1 = SPI_CR1_MSTR | SPI_CR1_SSM | SPI_CR1_SSI | ((uint32_t)EPD_SPI_BR << SPI_CR1_BR_Pos);
    SPI1->CR2 = 0xFu << SPI_CR2_DS_Pos;
    SPI1->CR1 |= SPI_CR1_SPE;

    // DMA1 channel 3 (request 1 = SPI1_TX): memory to SPI1->DR, 16-bit
    DMA1_CSELR->CSELR = (DMA1_CSELR->CSELR & ~DMA_CSELR_C3S) | (1u << DMA_CSELR_C3S_Pos);
    DMA1_Channel3->CCR  = 0;
    DMA1_Channel3->CPAR = (uint32_t)&SPI1->DR;
    DMA1_Channel3->CCR  = DMA_CCR_DIR | DMA_CCR_MINC | DMA_CCR_PSIZE_0 | DMA_CCR_MSIZE_0;
}

static void wait_ready(void) {
    uint32_t start = micros();
    while (!digitalRead(EPD_HRDY))
        if (micros() - start > HRDY_TIMEOUT_US) { timed_out = 1; return; }
}

static uint16_t xfer(uint16_t w) {
    while (!(SPI1->SR & SPI_SR_TXE));
    *(volatile uint16_t *)&SPI1->DR = w;
    while (!(SPI1->SR & SPI_SR_RXNE));
    return *(volatile uint16_t *)&SPI1->DR;
}

// wait for the last bit to leave, then drop what was received during a
// transmit-only DMA burst (it sets OVR)
static void spi_finish(void) {
    while (!(SPI1->SR & SPI_SR_TXE));
    while (SPI1->SR & SPI_SR_BSY);
    while (SPI1->SR & SPI_SR_RXNE) (void)*(volatile uint16_t *)&SPI1->DR;
    (void)SPI1->SR;
}

static void cs_low(void)  { digitalWrite(EPD_CS, 0); }
static void cs_high(void) { digitalWrite(EPD_CS, 1); }

static void write_cmd(uint16_t cmd) {
    wait_ready();
    cs_low();
    xfer(0x6000);
    wait_ready();
    xfer(cmd);
    cs_high();
}

static void write_data(uint16_t d) {
    wait_ready();
    cs_low();
    xfer(0x0000);
    wait_ready();
    xfer(d);
    cs_high();
}

static void read_data(uint16_t *buf, int n) {
    wait_ready();
    cs_low();
    xfer(0x1000);
    wait_ready();
    xfer(0);                        // dummy word
    wait_ready();
    for (int i = 0; i < n; i++) buf[i] = xfer(0);
    cs_high();
}

static void cmd_args(uint16_t cmd, const uint16_t *args, int n) {
    write_cmd(cmd);
    for (int i = 0; i < n; i++) write_data(args[i]);
}

static void write_reg(uint16_t addr, uint16_t val) {
    write_cmd(CMD_REG_WR);
    write_data(addr);
    write_data(val);
}

static uint16_t read_reg(uint16_t addr) {
    uint16_t v;
    write_cmd(CMD_REG_RD);
    write_data(addr);
    read_data(&v, 1);
    return v;
}

// ---- image data over DMA ----

static void dma_start(const uint8_t *buf, int words) {
    DMA1_Channel3->CCR  &= ~DMA_CCR_EN;
    DMA1_Channel3->CMAR  = (uint32_t)buf;
    DMA1_Channel3->CNDTR = (uint32_t)words;
    DMA1->IFCR = DMA_IFCR_CGIF3;
    DMA1_Channel3->CCR  |= DMA_CCR_EN;
    SPI1->CR2 |= SPI_CR2_TXDMAEN;
}

static void dma_wait(void) {
    uint32_t start = micros();
    while (!(DMA1->ISR & DMA_ISR_TCIF3))
        if (micros() - start > HRDY_TIMEOUT_US) { timed_out = 1; break; }
    SPI1->CR2 &= ~SPI_CR2_TXDMAEN;
    DMA1_Channel3->CCR &= ~DMA_CCR_EN;
    DMA1->IFCR = DMA_IFCR_CGIF3;
    spi_finish();
}

// ---- public ----

int it8951_busy(void) {
    return read_reg(REG_LUTAFSR) != 0;
}

static void wait_display_done(void) {
    uint32_t start = micros();
    while (it8951_busy())
        if (micros() - start > HRDY_TIMEOUT_US) { timed_out = 1; return; }
}

int it8951_draw(band_fn draw_band, int mode) {
    static uint8_t bufs[2][BAND_ROWS * ROW_BYTES];
    timed_out = 0;

    wait_display_done();

    // where to load, then the load area: 8-bpp pixels that each hold 8 real ones
    write_reg(REG_LISAR + 2, (uint16_t)(img_addr >> 16));
    write_reg(REG_LISAR, (uint16_t)(img_addr & 0xFFFF));
    uint16_t area[5] = {(ENDIAN_LITTLE << 8) | (PIX_8BPP << 4), 0, 0, IMG_W / 8, IMG_H};
    cmd_args(CMD_LD_IMG_AREA, area, 5);

    // draw band n+1 while DMA sends band n
    int cur = 0;
    draw_band(bufs[cur], 0, BAND_ROWS);
    for (int y0 = 0; y0 < IMG_H; y0 += BAND_ROWS) {
        wait_ready();
        cs_low();
        xfer(0x0000);
        wait_ready();
        dma_start(bufs[cur], BAND_ROWS * ROW_BYTES / 2);
        if (y0 + BAND_ROWS < IMG_H) draw_band(bufs[cur ^ 1], y0 + BAND_ROWS, BAND_ROWS);
        dma_wait();
        cs_high();
        cur ^= 1;
    }
    write_cmd(CMD_LD_IMG_END);

    // show it in 1-bpp mode: bit 1 = black, bit 0 = white
    uint16_t up1sr = read_reg(REG_UP1SR + 2);
    write_reg(REG_UP1SR + 2, up1sr | (1 << 2));
    write_reg(REG_BGVR, (GRAY_BLACK << 8) | GRAY_WHITE);
    uint16_t dpy[7] = {0, 0, IMG_W, IMG_H, (uint16_t)mode,
                       (uint16_t)(img_addr & 0xFFFF), (uint16_t)(img_addr >> 16)};
    cmd_args(CMD_DPY_BUF_AREA, dpy, 7);
    wait_display_done();
    write_reg(REG_UP1SR + 2, up1sr & ~(1 << 2));

    return !timed_out;
}

static void blank_band(uint8_t *buf, int y0, int rows) {
    (void)y0;
    memset(buf, 0, (size_t)rows * ROW_BYTES);
}

static void words_to_str(const uint16_t *w, char *s) {
    for (int i = 0; i < 8; i++) {
        s[2 * i]     = (char)(w[i] & 0xFF);
        s[2 * i + 1] = (char)(w[i] >> 8);
    }
    s[16] = 0;
}

int it8951_init(it8951_info_t *info) {
    uint16_t dev[20];

    spi_init();
    timed_out = 0;

    digitalWrite(EPD_RST, 0);
    delay_ms(20);
    digitalWrite(EPD_RST, 1);
    delay_ms(200);

    write_cmd(CMD_SYS_RUN);
    write_cmd(CMD_GET_DEV_INFO);
    read_data(dev, 20);
    if (timed_out) return 0;

    info->width        = dev[0];
    info->height       = dev[1];
    info->img_buf_addr = dev[2] | ((uint32_t)dev[3] << 16);
    words_to_str(&dev[4], info->fw_version);
    words_to_str(&dev[12], info->lut_version);
    img_addr = info->img_buf_addr;

    write_reg(REG_I80CPCR, 0x0001);

    // VCOM: read it, and write it only if it differs
    uint16_t vcom;
    write_cmd(CMD_VCOM);
    write_data(0x0000);
    read_data(&vcom, 1);
    if (vcom != EPD_VCOM_MV) {
        write_cmd(CMD_VCOM);
        write_data(0x0001);
        write_data(EPD_VCOM_MV);
    }
    if (timed_out) return 0;

    return it8951_draw(blank_band, EPD_MODE_INIT);
}
