#pragma once
// Master effects unit: echo, reverb (Freeverb-style) and flanger.
// process() is called from the audio thread only.
#include <algorithm>
#include <cmath>
#include <vector>

#include "biquad.hpp"

namespace fx {

constexpr int kEchoMax = 1 << 18;   // ~2.7 s at 96 kHz
constexpr int kFlangeMax = 4096;

struct Comb {
  std::vector<float> buf;
  int idx = 0;
  float store = 0;
  void init(int n) { buf.assign(std::max(1, n), 0.0f); idx = 0; store = 0; }
  float process(float in, float fb, float damp) {
    const float out = buf[idx];
    store = out * (1.0f - damp) + store * damp;
    buf[idx] = in + store * fb;
    if (++idx >= (int)buf.size()) idx = 0;
    return out;
  }
};

struct Allpass {
  std::vector<float> buf;
  int idx = 0;
  void init(int n) { buf.assign(std::max(1, n), 0.0f); idx = 0; }
  float process(float in) {
    const float b = buf[idx];
    const float out = b - in;
    buf[idx] = in + b * 0.5f;
    if (++idx >= (int)buf.size()) idx = 0;
    return out;
  }
};

struct Unit {
  // Settings written by the UI thread.
  // type: 0 off, 1 echo, 2 reverb, 3 flanger
  int sr = 0;
  std::vector<float> echoL, echoR, flL, flR;
  int echoPos = 0;
  int flPos = 0;
  float lfo = 0;
  static constexpr int kCombs = 8;
  static constexpr int kAll = 4;
  Comb combL[kCombs], combR[kCombs];
  Allpass apL[kAll], apR[kAll];
  float lpL = 0, lpR = 0; // gentle damping of echo repeats

  void prepare(int newSr) {
    if (newSr == sr) return;
    sr = newSr;
    echoL.assign(kEchoMax, 0.0f);
    echoR.assign(kEchoMax, 0.0f);
    flL.assign(kFlangeMax, 0.0f);
    flR.assign(kFlangeMax, 0.0f);
    echoPos = flPos = 0;
    static const int ct[kCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
    static const int at[kAll] = {556, 441, 341, 225};
    const float k = (float)sr / 44100.0f;
    for (int i = 0; i < kCombs; ++i) {
      combL[i].init((int)(ct[i] * k));
      combR[i].init((int)((ct[i] + 23) * k));
    }
    for (int i = 0; i < kAll; ++i) {
      apL[i].init((int)(at[i] * k));
      apR[i].init((int)((at[i] + 23) * k));
    }
  }

  // timeSec: echo delay (one beat etc.) or flanger rate scale; amount 0..1.
  void process(int type, float amount, float timeSec, float& l, float& r) {
    if (type <= 0 || sr == 0) return;
    const float a = std::max(0.0f, std::min(1.0f, amount));
    if (type == 1) {
      const int d = std::max(1, std::min(kEchoMax - 1, (int)(timeSec * sr)));
      int rp = echoPos - d;
      if (rp < 0) rp += kEchoMax;
      float wl = echoL[rp];
      float wr = echoR[rp];
      lpL += 0.6f * (wl - lpL);
      lpR += 0.6f * (wr - lpR);
      wl = lpL;
      wr = lpR;
      // ping-pong feedback
      echoL[echoPos] = l + wr * 0.55f;
      echoR[echoPos] = r + wl * 0.55f;
      if (++echoPos >= kEchoMax) echoPos = 0;
      l += wl * a;
      r += wr * a;
    } else if (type == 2) {
      const float in = (l + r) * 0.015f;
      float oL = 0, oR = 0;
      const float fb = 0.84f;
      const float damp = 0.25f;
      for (int i = 0; i < kCombs; ++i) {
        oL += combL[i].process(in, fb, damp);
        oR += combR[i].process(in, fb, damp);
      }
      for (int i = 0; i < kAll; ++i) {
        oL = apL[i].process(oL);
        oR = apR[i].process(oR);
      }
      l += oL * a * 3.0f;
      r += oR * a * 3.0f;
    } else if (type == 3) {
      const float rate = 0.15f + 0.5f * std::max(0.0f, std::min(4.0f, timeSec));
      lfo += 6.2831853f * rate / (float)sr;
      if (lfo > 6.2831853f) lfo -= 6.2831853f;
      const float dl = (0.0015f + 0.0012f * std::sin(lfo)) * sr;       // samples
      const float dr = (0.0015f + 0.0012f * std::sin(lfo + 1.57f)) * sr;
      auto tap = [&](std::vector<float>& b, float d) {
        float p = (float)flPos - d;
        while (p < 0) p += kFlangeMax;
        const int i0 = (int)p % kFlangeMax;
        const int i1 = (i0 + 1) % kFlangeMax;
        const float f = p - std::floor(p);
        return b[i0] * (1.0f - f) + b[i1] * f;
      };
      const float wl = tap(flL, dl);
      const float wr = tap(flR, dr);
      flL[flPos] = l + wl * 0.6f;
      flR[flPos] = r + wr * 0.6f;
      if (++flPos >= kFlangeMax) flPos = 0;
      l = l * (1.0f - 0.5f * a) + wl * a * 0.7f;
      r = r * (1.0f - 0.5f * a) + wr * a * 0.7f;
    }
  }
};

// Per-deck effect rack. Up to eight effects can be on at once, in this
// order: echo, reverb, flanger, phaser, gate, crush, wobble, roll.
struct DeckFx {
  Unit base; // echo, reverb and flanger share the master unit's code
  int sr = 0;
  // phaser
  float phX1[4][2] = {};
  float phY1[4][2] = {};
  float phFb[2] = {};
  float phLfo = 0;
  // gate
  float gateLfo = 0;
  float gateGain = 1;
  // crush
  int crushCount = 0;
  float crushL = 0;
  float crushR = 0;
  // wobble
  Biquad wobL, wobR;
  float wobLfo = 0;
  int wobTick = 0;
  // roll
  std::vector<float> rollL, rollR;
  int rollRec = 0;
  int rollLen = 0;
  int rollPos = 0;
  bool rollActive = false;

  void prepare(int newSr) {
    if (newSr == sr) return;
    sr = newSr;
    base.prepare(sr);
    rollL.assign(sr, 0.0f);
    rollR.assign(sr, 0.0f);
    wobL.lowPass((float)sr, 800.0f, 1.0f);
    wobR.lowPass((float)sr, 800.0f, 1.0f);
  }

  // mask bit 0 echo, 1 reverb, 2 flanger, 3 phaser, 4 gate, 5 crush,
  // 6 wobble, 7 roll. timeSec is the length of one beat.
  void process(int mask, float amount, float timeSec, float& l, float& r) {
    if (sr == 0) return;
    if (!(mask & 128)) rollActive = false;
    if (mask == 0) return;
    const float a = std::max(0.0f, std::min(1.0f, amount));
    const float beat = std::max(0.1f, std::min(2.5f, timeSec));
    if (mask & 1) base.process(1, a, beat, l, r);
    if (mask & 2) base.process(2, a, beat, l, r);
    if (mask & 4) base.process(3, a, beat, l, r);
    if (mask & 8) {
      phLfo += 6.2831853f / (beat * 8.0f * (float)sr);
      if (phLfo > 6.2831853f) phLfo -= 6.2831853f;
      const float fc = 400.0f + 2600.0f * (0.5f + 0.5f * std::sin(phLfo));
      const float t = std::tan(3.14159265f * fc / (float)sr);
      const float coef = (1.0f - t) / (1.0f + t);
      float* ch[2] = {&l, &r};
      for (int c = 0; c < 2; ++c) {
        const float in = *ch[c];
        float x = in + phFb[c] * 0.35f;
        for (int st = 0; st < 4; ++st) {
          const float y = -coef * x + phX1[st][c] + coef * phY1[st][c];
          phX1[st][c] = x;
          phY1[st][c] = y;
          x = y;
        }
        phFb[c] = x;
        *ch[c] = in * (1.0f - 0.5f * a) + x * (0.5f * a);
      }
    }
    if (mask & 16) {
      gateLfo += 1.0f / (beat * 0.5f * (float)sr);
      if (gateLfo >= 1.0f) gateLfo -= 1.0f;
      const float target = gateLfo < 0.5f ? 1.0f : 1.0f - a;
      gateGain += 0.01f * (target - gateGain);
      l *= gateGain;
      r *= gateGain;
    }
    if (mask & 32) {
      const int step = 1 + (int)(a * 20.0f);
      if (crushCount <= 0) {
        const float levels = std::exp2(12.0f - a * 7.0f);
        crushL = std::round(l * levels) / levels;
        crushR = std::round(r * levels) / levels;
        crushCount = step;
      }
      --crushCount;
      l = crushL;
      r = crushR;
    }
    if (mask & 64) {
      wobLfo += 6.2831853f / (beat * 2.0f * (float)sr);
      if (wobLfo > 6.2831853f) wobLfo -= 6.2831853f;
      if (++wobTick >= 32) {
        wobTick = 0;
        const float fc = 250.0f * std::exp2(3.2f * (0.5f + 0.5f * std::sin(wobLfo)));
        const float q = 1.0f + 3.0f * a;
        wobL.lowPass((float)sr, fc, q);
        wobR.lowPass((float)sr, fc, q);
      }
      l = wobL.process(l);
      r = wobR.process(r);
    }
    if (mask & 128) {
      if (!rollActive) {
        rollActive = true;
        rollLen = std::max(256, std::min(sr - 1, (int)(beat * 0.25f * (float)sr)));
        rollRec = 0;
        rollPos = 0;
      }
      if (rollRec < rollLen) {
        rollL[rollRec] = l;
        rollR[rollRec] = r;
        ++rollRec;
      } else {
        l = rollL[rollPos];
        r = rollR[rollPos];
        if (++rollPos >= rollLen) rollPos = 0;
      }
    }
  }
};

}  // namespace fx
