/* A canvas, two circles, two samples and buttons that play them, written
   in C against tinyweb.c. Build it with
     cc -o example example.c tinyweb.c
   then run ./example and open the address it prints. */

#include <stdio.h>

#include "tinyweb.h"

static int kick;
static int snare;
static int presses = 0;

static void play_kick(void)
{
    tinyweb_play_sample(kick, 0.0, 1.0, 1.0);
}

static void play_snare(void)
{
    presses += 1;
    printf("snare, press %d\n", presses);
    tinyweb_play_sample(snare, 0.0, 0.5, 1.0);
}

static void nothing(void)
{
}

int main(void)
{
    int canvas;
    tinyweb_web_init(0);
    kick = tinyweb_load_sample("kick1.wav");
    snare = tinyweb_load_sample("snare1.wav");
    canvas = tinyweb_canvas(400, 200);
    tinyweb_draw_circle(canvas, 100, 50, 30, "#ff0000");
    tinyweb_draw_circle(canvas, 100, 50, 20, "#000000");
    tinyweb_make_button("Play kick", play_kick);
    tinyweb_make_button("Play snare", play_snare);
    tinyweb_make_button("Does nothing", nothing);
    tinyweb_splash();
    printf("built the page\n");
    return 0;
}
