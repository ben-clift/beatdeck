#pragma once
// Records the master output to a 16 bit WAV file. The audio thread only
// copies samples into a ring buffer; a helper thread writes the file.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

class Recorder {
 public:
  ~Recorder() { stop(); }

  bool start(const char* path, int sampleRate) {
    if (active_.load()) return false;
    file_ = std::fopen(path, "wb");
    if (!file_) return false;
    sr_ = sampleRate;
    frames_ = 0;
    writeHeader(0);
    ring_.assign(kRing * 2, 0.0f);
    w_.store(0);
    r_ = 0;
    rAtomic_.store(0);
    framesDone_.store(0);
    stopFlag_.store(false);
    active_.store(true);
    thread_ = std::thread([this] { run(); });
    return true;
  }

  void stop() {
    if (!active_.load() && !thread_.joinable()) return;
    active_.store(false);
    stopFlag_.store(true);
    if (thread_.joinable()) thread_.join();
    if (file_) {
      writeHeader((uint32_t)(frames_ * 4));
      std::fclose(file_);
      file_ = nullptr;
    }
  }

  bool active() const { return active_.load(); }
  double seconds() const { return sr_ > 0 ? (double)framesDone_.load() / sr_ : 0.0; }

  // Audio thread. Drops samples if the writer falls behind.
  void push(float l, float r) {
    if (!active_.load(std::memory_order_relaxed)) return;
    const uint64_t w = w_.load(std::memory_order_relaxed);
    const uint64_t rd = rAtomic_.load(std::memory_order_acquire);
    if (w - rd >= kRing) return;
    const size_t i = (size_t)(w % kRing) * 2;
    ring_[i] = l;
    ring_[i + 1] = r;
    w_.store(w + 1, std::memory_order_release);
  }

 private:
  static constexpr uint64_t kRing = 1u << 18;  // about 5 s of stereo at 48 kHz

  void writeHeader(uint32_t dataBytes) {
    if (!file_) return;
    std::fseek(file_, 0, SEEK_SET);
    auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, file_); };
    auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, file_); };
    std::fwrite("RIFF", 1, 4, file_);
    u32(36 + dataBytes);
    std::fwrite("WAVEfmt ", 1, 8, file_);
    u32(16);
    u16(1);
    u16(2);
    u32((uint32_t)sr_);
    u32((uint32_t)sr_ * 4);
    u16(4);
    u16(16);
    std::fwrite("data", 1, 4, file_);
    u32(dataBytes);
    std::fseek(file_, 0, SEEK_END);
  }

  void drain() {
    std::vector<int16_t> out;
    for (;;) {
      const uint64_t w = w_.load(std::memory_order_acquire);
      if (r_ == w) break;
      out.clear();
      while (r_ < w && out.size() < 8192) {
        const size_t i = (size_t)(r_ % kRing) * 2;
        for (int c = 0; c < 2; ++c) {
          float v = ring_[i + c];
          if (v > 1.0f) v = 1.0f;
          if (v < -1.0f) v = -1.0f;
          out.push_back((int16_t)(v * 32767.0f));
        }
        ++r_;
      }
      rAtomic_.store(r_, std::memory_order_release);
      std::fwrite(out.data(), sizeof(int16_t), out.size(), file_);
      frames_ += out.size() / 2;
      framesDone_.store(frames_);
    }
  }

  void run() {
    while (!stopFlag_.load()) {
      drain();
      std::this_thread::sleep_for(std::chrono::milliseconds(30));
    }
    drain();
  }

  std::FILE* file_ = nullptr;
  int sr_ = 48000;
  uint64_t frames_ = 0;
  std::atomic<uint64_t> framesDone_{0};
  std::vector<float> ring_;
  std::atomic<uint64_t> w_{0};
  std::atomic<uint64_t> rAtomic_{0};
  uint64_t r_ = 0;
  std::atomic<bool> active_{false};
  std::atomic<bool> stopFlag_{false};
  std::thread thread_;
};
