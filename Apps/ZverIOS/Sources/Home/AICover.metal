#include <metal_stdlib>
using namespace metal;

// Абстрактная «дышащая» обложка AI-подборок: два слоя плавно плывущих
// цветовых волн + мягкое зерно. Детеминирована seed'ом (hue задаёт палитру
// секции), time двигает фазы. Эстетика Apple Music «Made for You»:
// медленно, глубоко, без кислотности.
//
// SwiftUI colorEffect: функция получает позицию пикселя и текущий цвет,
// возвращает новый. size передаём параметром для нормализации координат.
[[ stitchable ]] half4 aiCover(float2 position, half4 color,
                               float2 size, float time, float hue) {
    float2 uv = position / max(size.x, size.y);

    // Медленные фазы: полный «вдох» ~20с, чтобы плитка жила, а не мельтешила.
    float t = time * 0.18;

    // Две волновые компоненты с разными частотами дают нерегулярный,
    // «жидкий» узор без видимой периодичности на плитке.
    float w1 = sin(uv.x * 3.1 + t) * cos(uv.y * 2.3 - t * 0.7);
    float w2 = sin((uv.x + uv.y) * 4.7 - t * 1.3) * 0.5;
    float blend = 0.5 + 0.5 * (w1 * 0.6 + w2 * 0.4);

    // Палитра: базовый hue секции и его сосед через ~0.12 круга — родственные,
    // не контрастные. Светимость волной, насыщенность умеренная.
    float h1 = fract(hue);
    float h2 = fract(hue + 0.12 + 0.05 * sin(t * 0.5));
    float h = mix(h1, h2, blend);
    float s = 0.55 + 0.15 * sin(t + uv.y * 2.0);
    float v = 0.45 + 0.35 * blend;

    // HSV → RGB (компактно, без ветвлений).
    float3 k = float3(1.0, 2.0 / 3.0, 1.0 / 3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    float3 rgb = v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);

    // Виньетка к краям — плитка читается объёмнее, текст поверх контрастнее.
    float2 centered = uv - float2(0.5);
    rgb *= 1.0 - 0.35 * dot(centered, centered) * 2.0;

    return half4(half3(rgb), color.a);
}
