#pragma once
// Master effects unit: echo, reverb (Freeverb-style) and flanger.
// process() is called from the audio thread only.
#include <algorithm>
#include <cmath>
#include <vector>

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

}  // namespace fx
