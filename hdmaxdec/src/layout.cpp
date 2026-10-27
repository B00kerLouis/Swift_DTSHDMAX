// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "internal.hpp"
namespace {
using Speaker = hdmaxdec_speaker;
struct Position {
  double azimuth, elevation;
};
Position position(Speaker s) {
  switch (s) {
  case HD_FL:
    return {-30, 0};
  case HD_FR:
    return {30, 0};
  case HD_FC:
    return {0, 0};
  case HD_BL:
    return {-150, 0};
  case HD_BR:
    return {150, 0};
  case HD_SL:
    return {-90, 0};
  case HD_SR:
    return {90, 0};
  case HD_FLC:
    return {-15, 0};
  case HD_FRC:
    return {15, 0};
  case HD_BC:
    return {180, 0};
  case HD_WL:
    return {-60, 0};
  case HD_WR:
    return {60, 0};
  case HD_TFL:
    return {-30, 45};
  case HD_TFR:
    return {30, 45};
  case HD_TFC:
    return {0, 45};
  case HD_TBL:
    return {-150, 45};
  case HD_TBR:
    return {150, 45};
  case HD_TBC:
    return {180, 45};
  case HD_TSL:
    return {-90, 90};
  case HD_TSR:
    return {90, 90};
  case HD_TC:
    return {0, 90};
  default:
    return {0, -1000};
  }
}
bool valid(const hdmaxdec_layout *l) {
  if (!l || !l->count || l->count > 32)
    return false;
  for (uint32_t c = 0; c < l->count; ++c) {
    if (l->speakers[c] != HD_LFE && position(l->speakers[c]).elevation < 0)
      return false;
    for (uint32_t i = 0; i < c; ++i)
      if (l->speakers[i] == l->speakers[c])
        return false;
  }
  return true;
}
} // namespace
extern "C" {
const char *hdmaxdec_speaker_name(Speaker s) {
  switch (s) {
  case HD_FL:
    return "FL";
  case HD_FR:
    return "FR";
  case HD_FC:
    return "FC";
  case HD_LFE:
    return "LFE";
  case HD_BL:
    return "BL";
  case HD_BR:
    return "BR";
  case HD_SL:
    return "SL";
  case HD_SR:
    return "SR";
  case HD_FLC:
    return "FLC";
  case HD_FRC:
    return "FRC";
  case HD_BC:
    return "BC";
  case HD_TC:
    return "TC";
  case HD_TFL:
    return "TFL";
  case HD_TFC:
    return "TFC";
  case HD_TFR:
    return "TFR";
  case HD_TBL:
    return "TBL";
  case HD_TBC:
    return "TBC";
  case HD_TBR:
    return "TBR";
  case HD_WL:
    return "WL";
  case HD_WR:
    return "WR";
  case HD_TSL:
    return "TSL";
  case HD_TSR:
    return "TSR";
  default:
    return "UNKNOWN";
  }
}
int hdmaxdec_layout_named(const char *name, hdmaxdec_layout *l) {
  if (!name || !l)
    return HD_INVALID;
  *l = {};
  struct Named {
    const char *name;
    int bed, height;
    bool tfc, wide;
  };
  static const Named names[] = {
      {"2.0", 2, 0, false, false},   {"5.1", 6, 0, false, false},
      {"7.1", 8, 0, false, false},   {"5.1.2", 6, 2, false, false},
      {"5.1.4", 6, 4, false, false}, {"7.1.2", 8, 2, false, false},
      {"7.1.4", 8, 4, false, false}, {"7.1.5", 8, 4, true, false},
      {"7.1.6", 8, 6, false, false}, {"9.1.6", 8, 6, false, true}};
  for (const auto &n : names)
    if (!std::strcmp(n.name, name)) {
      Speaker bed[] = {HD_FL, HD_FR, HD_FC, HD_LFE, HD_BL, HD_BR, HD_SL, HD_SR};
      if (n.bed == 6) {
        bed[4] = HD_SL;
        bed[5] = HD_SR;
      }
      for (int c = 0; c < n.bed; ++c)
        l->speakers[l->count++] = bed[c];
      if (n.wide) {
        l->speakers[l->count++] = HD_WL;
        l->speakers[l->count++] = HD_WR;
      }
      if (n.height == 2) {
        l->speakers[l->count++] = HD_TFL;
        l->speakers[l->count++] = HD_TFR;
      } else if (n.height) {
        Speaker tops[] = {HD_TFL, HD_TFR, HD_TBL, HD_TBR, HD_TSL, HD_TSR};
        for (int c = 0; c < n.height; ++c)
          l->speakers[l->count++] = tops[c];
      }
      if (n.tfc)
        l->speakers[l->count++] = HD_TFC;
      return HD_OK;
    }
  return HD_UNSUPPORTED;
}
int hdmaxdec_mix_matrix(const hdmaxdec_layout *in, const hdmaxdec_layout *out,
                        float *m) {
  if (!valid(in) || !valid(out) || !m)
    return HD_INVALID;
  std::fill(m, m + in->count * out->count, 0.0f);
  for (uint32_t i = 0; i < in->count; ++i) {
    Speaker s = in->speakers[i];
    bool exact = false;
    for (uint32_t o = 0; o < out->count; ++o)
      if (s == out->speakers[o]) {
        m[o * in->count + i] = 1;
        exact = true;
        break;
      }
    if (exact)
      continue;
    Speaker alternate = s == HD_BL   ? HD_SL
                        : s == HD_BR ? HD_SR
                        : s == HD_SL ? HD_BL
                        : s == HD_SR ? HD_BR
                                     : HD_UNKNOWN;
    if (alternate != HD_UNKNOWN) {
      for (uint32_t o = 0; o < out->count; ++o)
        if (alternate == out->speakers[o]) {
          m[o * in->count + i] = 1;
          exact = true;
          break;
        }
      if (exact)
        continue;
    }
    // LFE contains band-limited effects, never synthetic bass management.
    if (s == HD_LFE)
      continue;
    Position src = position(s);
    std::array<std::pair<double, uint32_t>, HDMAXDEC_MAX_CHANNELS> choices{};
    size_t choiceCount = 0;
    bool hasTop = false;
    for (uint32_t o = 0; o < out->count; ++o)
      hasTop |= position(out->speakers[o]).elevation > 0;
    for (uint32_t o = 0; o < out->count; ++o) {
      Speaker dst = out->speakers[o];
      if (dst == HD_LFE)
        continue;
      Position p = position(dst);
      if (src.elevation > 0 && hasTop && p.elevation == 0)
        continue;
      if (src.elevation == 0 && p.elevation > 0)
        continue;
      double da = std::abs(src.azimuth - p.azimuth);
      da = std::min(da, 360 - da);
      double de = src.elevation - p.elevation;
      choices[choiceCount++] = {std::sqrt(da * da + de * de), o};
    }
    if (!choiceCount)
      return HD_UNSUPPORTED;
    std::sort(choices.begin(), choices.begin() + choiceCount);
    size_t n = std::min<size_t>(2, choiceCount);
    // Stereo uses explicit conventional center/surround folds. Spatial
    // folding elsewhere selects nearest positions with equal-power gains.
    if (out->count == 2 && out->speakers[0] == HD_FL &&
        out->speakers[1] == HD_FR) {
      if (src.azimuth == 0 || std::abs(src.azimuth) == 180) {
        m[i] = 0.70710678f;
        m[in->count + i] = 0.70710678f;
      } else
        m[(src.azimuth < 0 ? 0 : in->count) + i] = 0.70710678f;
      continue;
    }
    double weights[2] = {1, 0};
    if (n == 2) {
      double d0 = choices[0].first, d1 = choices[1].first;
      weights[0] = d1 / (d0 + d1);
      weights[1] = d0 / (d0 + d1);
      double norm = std::hypot(weights[0], weights[1]);
      weights[0] /= norm;
      weights[1] /= norm;
    }
    double elevationGain =
        src.elevation > 0 && !hasTop ? 0.7071067811865476 : 1;
    for (size_t j = 0; j < n; ++j)
      m[choices[j].second * in->count + i] = float(weights[j] * elevationGain);
  }
  return HD_OK;
}
int hdmaxdec_frame_mix_matrix(const hdmaxdec_frame *f,
                              const hdmaxdec_layout *out, float *m) {
  if (!f || !out)
    return HD_INVALID;
  int status = hdmaxdec_mix_matrix(&f->layout, out, m);
  if (status || !f->immersive)
    return status;
  for (uint32_t o = 0; o < out->count; ++o)
    if (position(out->speakers[o]).elevation > 0)
      return HD_OK;
  auto input = [&](Speaker s) -> int {
    for (uint32_t c = 0; c < f->layout.count; ++c)
      if (f->layout.speakers[c] == s)
        return int(c);
    return -1;
  };
  auto fold = [&](Speaker speaker,
                  std::initializer_list<std::pair<Speaker, float>> routes) {
    int top = input(speaker);
    if (top < 0)
      return true;
    for (uint32_t o = 0; o < out->count; ++o) {
      float value = 0;
      for (const auto &route : routes) {
        int bed = input(route.first);
        if (bed < 0)
          return false;
        value += route.second * m[o * f->layout.count + uint32_t(bed)];
      }
      m[o * f->layout.count + uint32_t(top)] = value;
    }
    return true;
  };
  Speaker rearLeft = input(HD_BL) >= 0 ? HD_BL : HD_SL;
  Speaker rearRight = input(HD_BR) >= 0 ? HD_BR : HD_SR;
  float gain = f->immersive == 2 ? 1.0f : 23170.0f / 32768;
  if (!fold(HD_TFL, {{HD_FL, gain}}) || !fold(HD_TFR, {{HD_FR, gain}}) ||
      !fold(HD_TBL, {{rearLeft, gain}}) || !fold(HD_TBR, {{rearRight, gain}}) ||
      !fold(HD_TSL, {{HD_SL, 23170.0f / 32768}}) ||
      !fold(HD_TSR, {{HD_SR, 23170.0f / 32768}}) ||
      !fold(HD_TBC,
            {{rearLeft, 16423.0f / 32768}, {rearRight, 16423.0f / 32768}}))
    return HD_INVALID;
  if (f->immersive == 2) {
    if (!fold(HD_TFC, {{HD_FL, 13818.0f / 32768},
                       {HD_FR, 13818.0f / 32768},
                       {HD_FC, 27571.0f / 32768}}))
      return HD_INVALID;
  } else if (!fold(HD_TFC, {{HD_FC, 23170.0f / 32768}}))
    return HD_INVALID;
  return HD_OK;
}
int hdmaxdec_render_float(const hdmaxdec_frame *f, const hdmaxdec_layout *out,
                          float gain, float *pcm, size_t capacity) {
  if (!f || !out || !pcm || !std::isfinite(gain) || gain < 0 ||
      !valid(&f->layout) || !valid(out) || f->sample_count > 65536 ||
      capacity < size_t(f->sample_count) * out->count)
    return HD_INVALID;
  for (uint32_t c = 0; c < f->layout.count; ++c)
    if (!f->planes[c])
      return HD_INVALID;
  float m[32 * 32];
  for (uint32_t c = 0; c < f->layout.count; ++c)
    for (uint32_t i = 0; i < f->sample_count; ++i)
      if (f->planes[c][i] < -8388608 || f->planes[c][i] > 8388607)
        return HD_INVALID;
  int status = hdmaxdec_frame_mix_matrix(f, out, m);
  if (status)
    return status;
  for (uint32_t i = 0; i < f->sample_count; ++i)
    for (uint32_t o = 0; o < out->count; ++o) {
      double v = 0;
      for (uint32_t c = 0; c < f->layout.count; ++c)
        v += double(f->planes[c][i]) * m[o * f->layout.count + c];
      pcm[size_t(i) * out->count + o] =
          float(std::clamp(v * gain / 8388608, -1.0, 1.0));
    }
  return HD_OK;
}
}

namespace hd {
// The 7.1.4 display panner uses speaker-anchored spherical directions. Distance
// is preserved by metadata validation but does not spread this speaker image.
std::array<double, 12> objectImage(int azimuth, int elevation) {
  using V = std::array<float, 3>;
  struct Patch {
    std::array<int, 3> channels;
    std::array<V, 3> inverse;
  };
  constexpr float pi = 3.14159265358979323846f;
  const auto direction = [](float az, float el) -> V {
    float a = az * pi / 180, e = el * pi / 180;
    return {std::sin(a) * std::cos(e), std::cos(a) * std::cos(e), std::sin(e)};
  };
  static const auto patches = [&] {
    const float angles[][2] = {{-30, 0},  {30, 0},  {0, 0},     {0, 0},
                               {-90, 0},  {90, 0},  {-150, 0},  {150, 0},
                               {-45, 45}, {45, 45}, {-135, 45}, {135, 45}};
    const int indices[][3] = {{0, 2, 8},   {0, 4, 8},  {2, 1, 9},  {2, 8, 9},
                              {1, 5, 9},   {4, 6, 10}, {4, 8, 10}, {5, 7, 11},
                              {5, 9, 11},  {6, 7, 10}, {6, 7, 11}, {6, 10, 11},
                              {7, 10, 11}, {8, 9, 10}, {8, 9, 11}, {8, 10, 11},
                              {9, 10, 11}};
    std::vector<Patch> result;
    for (const auto &ix : indices) {
      std::array<V, 3> a;
      for (int i = 0; i < 3; ++i)
        a[i] = direction(angles[ix[i]][0], angles[ix[i]][1]);
      float det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
                  a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
                  a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
      if (std::abs(det) <= 8 * std::numeric_limits<float>::epsilon())
        continue;
      float inv = 1 / det;
      result.push_back({{ix[0], ix[1], ix[2]},
                        {{{{inv * (a[1][1] * a[2][2] - a[1][2] * a[2][1]),
                            inv * (a[0][2] * a[2][1] - a[0][1] * a[2][2]),
                            inv * (a[0][1] * a[1][2] - a[0][2] * a[1][1])}},
                          {{inv * (a[1][2] * a[2][0] - a[1][0] * a[2][2]),
                            inv * (a[0][0] * a[2][2] - a[0][2] * a[2][0]),
                            inv * (a[0][2] * a[1][0] - a[0][0] * a[1][2])}},
                          {{inv * (a[1][0] * a[2][1] - a[1][1] * a[2][0]),
                            inv * (a[0][1] * a[2][0] - a[0][0] * a[2][1]),
                            inv * (a[0][0] * a[1][1] - a[0][1] * a[1][0])}}}}});
    }
    return result;
  }();
  float az = azimuth == 47    ? -110
             : azimuth == 193 ? 110
                              : float(azimuth) * 1.5f - 180;
  V v = direction(az, float(elevation - 60) * 1.5f);
  float length = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  if (length > 1e-7f)
    for (float &c : v)
      c /= length;
  std::array<float, 12> gains{};
  float active = 0, epsilon = 8 * std::numeric_limits<float>::epsilon();
  for (const auto &patch : patches) {
    V c{};
    int significant = 0;
    bool outside = false;
    for (int i = 0; i < 3; ++i) {
      c[i] = v[0] * patch.inverse[0][i] + v[1] * patch.inverse[1][i] +
             v[2] * patch.inverse[2][i];
      outside |= c[i] < -epsilon;
      significant += c[i] > epsilon;
    }
    if (outside)
      continue;
    float weight = significant == 2 ? 0.5f : 1;
    for (int i = 0; i < 3; ++i)
      gains[patch.channels[i]] += c[i] * weight;
    active += weight;
    if (significant == 1)
      break;
  }
  if (active > 0)
    for (float &g : gains)
      g /= active;
  float power = 0;
  for (float g : gains)
    power += g * g;
  float norm = std::sqrt(power);
  std::array<double, 12> result{};
  if (norm > 1e-12f)
    for (size_t i = 0; i < gains.size(); ++i)
      result[i] = double(gains[i] / norm);
  return result;
}
} // namespace hd
