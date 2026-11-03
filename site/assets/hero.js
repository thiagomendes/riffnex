// A silent, looping picture of the RIFFNEX practice screen: a riff caught in a ring that turns
// with the beat, sparks on the guitar's attacks, and the neck with notes coming toward you.
(() => {
  document.documentElement.classList.add("js");

  // Reveal sections as they scroll in.
  const io = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }, { threshold: 0.12 }) : null;
  document.querySelectorAll(".reveal").forEach((el) => (io ? io.observe(el) : el.classList.add("in")));

  const canvas = document.getElementById("arena");
  if (!canvas) return;
  const g = canvas.getContext("2d");
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const C = { fire: "#ff6a2b", fire2: "#ffc23d", cyan: "#33e1ff", magenta: "#ff3d9a", fg: "#f4f1ff", line: "#2c2650" };
  const lanes = ["#FF4D5E", "#FF8A2B", "#FFC83D", "#3DE38A", "#33C8FF", "#B46BFF"];

  // A two-bar riff at 104 BPM: string, fret, start (in eighths).
  const BEAT = 60 / 104, E8 = BEAT / 2, LOOP = 8 * BEAT;
  const riff = [[0, 0, 0], [0, 0, 2], [0, 3, 3], [1, 2, 5], [2, 2, 6], [1, 0, 7],
                [0, 0, 8], [0, 0, 10], [3, 2, 11], [2, 4, 12], [1, 2, 13], [4, 3, 14], [1, 0, 15]];
  const notes = riff.map(([s, f, i]) => ({ s, f, t: i * E8, d: E8 * (f === 0 && i % 2 === 0 ? 0.6 : 0.9) }));
  const bins = 160;
  const guitar = new Float32Array(bins), band = new Float32Array(bins);
  const hash = (i) => { const x = Math.sin(i * 12.9898) * 43758.5453; return x - Math.floor(x); };
  for (let b = 0; b < bins; b++) {
    const t = (b / bins) * LOOP;
    let gv = 0, bv = 0;
    for (const n of notes) if (t >= n.t) gv += Math.exp(-(t - n.t) / (n.f === 0 ? 0.08 : 0.3));
    for (let k = 0; k < 8; k++) {
      const kt = k * BEAT;
      if (t >= kt) bv += (k % 2 ? 0.8 : 1.1) * Math.exp(-(t - kt) / 0.11);
    }
    guitar[b] = (1 - Math.exp(-gv * 1.3)) * (0.85 + 0.15 * hash(b));
    band[b] = (1 - Math.exp(-(bv + 0.3) * 1.1)) * (0.8 + 0.2 * hash(b + 99));
  }

  let W = 0, H = 0, dpr = 1;
  function resize() {
    const r = canvas.getBoundingClientRect();
    dpr = Math.min(2, window.devicePixelRatio || 1);
    W = r.width; H = r.height;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  window.addEventListener("resize", resize);
  resize();

  const sparks = [];
  let last = performance.now(), song = 0, lastPhase = 0, laps = 3, lapFlash = 0, start = performance.now();
  const speed = 0.75;

  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000); last = now;
    if (!reduce) song += dt * speed;
    const phase = (song % LOOP) / LOOP;
    if (phase < lastPhase) { laps++; lapFlash = 1; }
    // Sparks when a note reaches the top of the ring.
    for (const n of notes) {
      const p = n.t / LOOP;
      if ((lastPhase < p && phase >= p) || (phase < lastPhase && (p > lastPhase || p <= phase))) emit(n.f === 0 ? 5 : 10);
    }
    lastPhase = phase;
    lapFlash = Math.max(0, lapFlash - dt * 2);
    const appear = Math.min(1, (now - start) / 1200);
    draw(phase, dt, appear);
    if (!reduce || appear < 1) requestAnimationFrame(frame);
  }

  function geo() {
    const cx = W / 2, rcy = H * 0.34, R = Math.min(W * 0.24, H * 0.13);
    return { cx, rcy, R, depth: R * 0.4, meter: R * 1.4 + 18 };
  }
  function emit(n) {
    const { cx, rcy, R, depth } = geo();
    for (let i = 0; i < n; i++) {
      const a = -Math.PI / 2 + (Math.random() - 0.5) * 2.4, v = 1.2 + Math.random() * 2.4;
      sparks.push({ x: cx, y: rcy - R - depth, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: 1, r: 1 + Math.random() * 1.6, hot: Math.random() < 0.6 });
    }
  }

  function draw(phase, dt, appear) {
    g.clearRect(0, 0, W, H);
    const bg = g.createRadialGradient(W / 2, H * 0.34, 0, W / 2, H * 0.34, H * 0.7);
    bg.addColorStop(0, "#1a1438"); bg.addColorStop(0.55, "#0f0c22"); bg.addColorStop(1, "#07060f");
    g.fillStyle = bg; g.fillRect(0, 0, W, H);
    const beatPhase = ((phase * LOOP) % BEAT) / BEAT;
    const pulse = Math.exp(-beatPhase * 7);
    const { cx, rcy, R, depth, meter } = geo();
    const e = 0.5 - Math.cos(Math.PI * appear) / 2;

    // HUD
    g.fillStyle = C.fg; g.font = "800 13px 'Chakra Petch', sans-serif"; g.textAlign = "left";
    g.fillText("SUA MÚSICA", 18, 34);
    g.fillStyle = "rgba(244,241,255,0.5)"; g.font = "500 10px 'Chakra Petch', sans-serif";
    g.fillText("GUITARRA SEPARADA NO IPHONE", 18, 50);

    // Ring of the caught riff
    const scale = 1 + 0.035 * pulse;
    g.lineCap = "round";
    for (const [arr, color, k, alpha] of [[band, C.cyan, 1, 0.8], [guitar, C.fire, 0.8, 1]]) {
      g.strokeStyle = color;
      for (const [w, a] of [[6, 0.16], [2, 1]]) {
        g.globalCompositeOperation = w > 3 ? "lighter" : "source-over";
        g.globalAlpha = alpha * a * e; g.lineWidth = w;
        g.beginPath();
        for (let b = 0; b < bins; b++) {
          const h = arr[b] * k;
          if (h < 0.02) continue;
          let d = b / bins - phase; d -= Math.floor(d);
          const th = -Math.PI / 2 + d * Math.PI * 2;
          const ro = (R + h * depth) * scale * e, ri = (R - h * depth * 0.55) * scale * e;
          g.moveTo(cx + Math.cos(th) * ro, rcy + Math.sin(th) * ro);
          g.lineTo(cx + Math.cos(th) * ri, rcy + Math.sin(th) * ri);
        }
        g.stroke();
      }
    }
    g.globalCompositeOperation = "source-over"; g.globalAlpha = e;

    // Speed meter: 75%
    const segs = 12, frac = (speed - 0.4) / 0.6;
    for (let i = 0; i < segs; i++) {
      const a0 = -Math.PI / 2 + (i / segs) * Math.PI * 2 + 0.035, a1 = -Math.PI / 2 + ((i + 1) / segs) * Math.PI * 2 - 0.035;
      const lit = (i + 1) / segs <= frac + 1e-6;
      g.strokeStyle = lit ? (i >= 6 ? C.fire : C.fire2) : "rgba(255,255,255,0.08)";
      g.lineWidth = lit ? 6 : 4;
      g.shadowColor = g.strokeStyle; g.shadowBlur = lit ? 8 : 0;
      g.beginPath(); g.arc(cx, rcy, meter, a0, a1); g.stroke();
    }
    g.shadowBlur = 0;
    if (lapFlash > 0) {
      g.globalCompositeOperation = "lighter"; g.globalAlpha = 0.6 * lapFlash * e;
      g.strokeStyle = C.magenta; g.lineWidth = 2 + 8 * lapFlash;
      g.beginPath(); g.arc(cx, rcy, meter, 0, Math.PI * 2); g.stroke();
      g.globalCompositeOperation = "source-over"; g.globalAlpha = e;
    }
    // Playhead
    g.fillStyle = C.fg; g.shadowColor = C.magenta; g.shadowBlur = 10;
    g.fillRect(cx - 1, rcy - R - depth - 10, 2, depth * 1.6 + 10); g.shadowBlur = 0;
    // Center
    g.textAlign = "center"; g.textBaseline = "middle";
    const grad = g.createLinearGradient(0, rcy - R * 0.5, 0, rcy + R * 0.2);
    grad.addColorStop(0, "#fff"); grad.addColorStop(1, C.fire2);
    g.fillStyle = grad; g.font = `400 ${Math.round(R * 0.62)}px 'Russo One', sans-serif`;
    g.fillText(String(laps), cx, rcy - R * 0.1);
    g.fillStyle = "rgba(244,241,255,0.45)"; g.font = "700 9px 'Chakra Petch', sans-serif";
    g.fillText("V O L T A S", cx, rcy + R * 0.32);
    g.fillStyle = C.fire2; g.font = "700 13px 'Chakra Petch', sans-serif";
    g.fillText("75%", cx, rcy + R * 0.55);
    g.textBaseline = "alphabetic";

    drawNeck(phase, pulse, e);

    // Sparks
    g.globalCompositeOperation = "lighter";
    for (let i = sparks.length - 1; i >= 0; i--) {
      const p = sparks[i];
      p.x += p.vx; p.y += p.vy; p.vy += 0.07; p.life -= dt * 1.4;
      if (p.life <= 0) { sparks.splice(i, 1); continue; }
      g.globalAlpha = p.life * e; g.fillStyle = p.hot ? C.fire : C.fire2;
      g.beginPath(); g.arc(p.x, p.y, p.r, 0, Math.PI * 2); g.fill();
    }
    g.globalCompositeOperation = "source-over"; g.globalAlpha = 1;
  }

  function drawNeck(phase, pulse, e) {
    const horizon = H * 0.6, strike = H * 0.88, bottomHalf = W * 0.44, topHalf = W * 0.09, cx = W / 2;
    const LA = 2.2;
    const persp = (z) => { z = Math.max(z, -0.1); return (1.55 * z) / (z + 0.55); };
    const Y = (z) => strike - (strike - horizon) * persp(z);
    const HW = (z) => bottomHalf + (topHalf - bottomHalf) * persp(z);
    const X = (s, z) => cx + HW(z) * (1 - (2 * s) / 5) * 0.84;
    const S = (z) => 1 - 0.7 * persp(Math.max(z, 0));
    g.save(); g.globalAlpha = e; g.translate(0, 20 * (1 - e));
    const bottom = Y(-0.1);
    g.beginPath(); g.moveTo(cx - topHalf, horizon); g.lineTo(cx + topHalf, horizon); g.lineTo(cx + HW(-0.1), bottom); g.lineTo(cx - HW(-0.1), bottom); g.closePath();
    const lg = g.createLinearGradient(0, horizon, 0, bottom);
    lg.addColorStop(0, "rgba(18,11,46,0.3)"); lg.addColorStop(0.55, "rgba(26,16,64,0.92)"); lg.addColorStop(1, "#0c0820");
    g.fillStyle = lg; g.fill();
    for (const side of [-1, 1]) {
      g.shadowColor = C.magenta; g.shadowBlur = 6; g.strokeStyle = C.magenta; g.lineWidth = 2;
      g.beginPath(); g.moveTo(cx + side * topHalf, horizon); g.lineTo(cx + side * HW(-0.1), bottom); g.stroke(); g.shadowBlur = 0;
    }
    const songT = phase * LOOP;
    for (let k = Math.ceil(songT / BEAT); k * BEAT <= songT + LA; k++) {
      const z = (k * BEAT - songT) / LA; const y = Y(z), h = HW(z);
      g.strokeStyle = `rgba(255,255,255,${(k % 4 === 0 ? 0.45 : 0.18) * (1 - z * 0.6)})`; g.lineWidth = k % 4 === 0 ? 1.6 : 0.8;
      g.beginPath(); g.moveTo(cx - h, y); g.lineTo(cx + h, y); g.stroke();
    }
    const upcoming = [];
    for (let rep = 0; rep < 3; rep++) for (const n of notes) {
      const t = n.t + rep * LOOP;
      if (t + n.d >= songT - 0.2 && t <= songT + LA) upcoming.push({ ...n, t });
    }
    for (let s = 0; s < 6; s++) {
      const held = upcoming.some((n) => n.s === s && n.t <= songT && songT < n.t + n.d);
      g.strokeStyle = held ? lanes[s] : lanes[s] + "66"; g.lineWidth = 2.4 - 0.3 * s + (held ? 1 : 0);
      if (held) { g.shadowColor = lanes[s]; g.shadowBlur = 8; }
      g.beginPath(); g.moveTo(X(s, 1), horizon); g.lineTo(X(s, -0.1), bottom); g.stroke(); g.shadowBlur = 0;
    }
    g.shadowColor = C.magenta; g.shadowBlur = 5 + 6 * pulse; g.strokeStyle = "rgba(255,255,255,0.6)"; g.lineWidth = 1.5;
    g.beginPath(); g.moveTo(cx - HW(0), strike); g.lineTo(cx + HW(0), strike); g.stroke(); g.shadowBlur = 0;
    for (let s = 0; s < 6; s++) {
      const x = X(s, 0), held = upcoming.some((n) => n.s === s && n.t <= songT && songT < n.t + n.d);
      g.fillStyle = "rgba(7,6,15,0.85)"; g.beginPath(); g.ellipse(x, strike, 16, 10, 0, 0, Math.PI * 2); g.fill();
      if (held) {
        g.shadowColor = lanes[s]; g.shadowBlur = 12;
        const rr = g.createRadialGradient(x, strike, 0, x, strike, 16); rr.addColorStop(0, "#fff"); rr.addColorStop(1, lanes[s]);
        g.fillStyle = rr; g.beginPath(); g.ellipse(x, strike, 16, 10, 0, 0, Math.PI * 2); g.fill(); g.shadowBlur = 0;
      }
      g.strokeStyle = lanes[s]; g.lineWidth = 2; g.beginPath(); g.ellipse(x, strike, 16, 10, 0, 0, Math.PI * 2); g.stroke();
    }
    upcoming.sort((a, b) => b.t - a.t);
    for (const n of upcoming) {
      const z = (n.t - songT) / LA; if (z < -0.04 || z > 1.02) continue;
      const s = S(z), x = X(n.s, z), y = Y(z), rx = 15 * s, ry = 10 * s;
      g.save(); g.shadowColor = lanes[n.s]; g.shadowBlur = 6 * s;
      const rr = g.createRadialGradient(x, y - ry * 0.4, 0, x, y - ry * 0.4, rx * 1.2);
      rr.addColorStop(0, lanes[n.s]); rr.addColorStop(1, "#3a1530");
      g.fillStyle = rr; g.beginPath(); g.ellipse(x, y, rx, ry, 0, 0, Math.PI * 2); g.fill(); g.restore();
      g.strokeStyle = "rgba(255,255,255,0.7)"; g.lineWidth = Math.max(1, 1.4 * s); g.stroke();
      if (s > 0.45) {
        g.fillStyle = "#14081f"; g.font = `400 ${Math.round(13 * s)}px 'Russo One', sans-serif`; g.textAlign = "center"; g.textBaseline = "middle";
        g.fillText(String(n.f), x, y + 0.5); g.textBaseline = "alphabetic";
      }
    }
    g.fillStyle = C.fg; g.font = "400 22px 'Russo One', sans-serif"; g.textAlign = "center";
    g.shadowColor = C.magenta; g.shadowBlur = 10;
    g.fillText(phase < 0.5 ? "E5" : "A", cx, horizon + 28); g.shadowBlur = 0;
    g.restore();
  }

  requestAnimationFrame(frame);
})();
