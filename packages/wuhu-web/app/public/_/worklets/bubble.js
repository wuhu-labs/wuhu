// Paint worklet (CSS Paint API, Chromium): one outline per message bubble, tail included.
// background: paint(bubble) on a box that covers the bubble, plus TAIL px below it when --bubble-tail is 1.
// One line: a pill. Taller: iOS continuous corners. Tail traced from Hazel's iMessage shot (2026-10-21).
const TAIL = 7;
const PILL = 16.25; // cap radius the tail was fitted on (one-line bubble); tail px are relative to the bubble's bottom-right
const TAIL_FROM = (53.296 * Math.PI) / 180; // cap angle where the tail takes over

// iOS continuous corner, one quarter, in units of r: x back along the incoming edge, y into the turn.
const CORNER = [
  ["M", 1.52866, 0],
  ["C", 1.08849, 0, 0.86841, 0, 0.66993, 0.0655],
  ["L", 0.63149, 0.07491],
  ["C", 0.37282, 0.16906, 0.16906, 0.37282, 0.07491, 0.63149],
  ["L", 0.0655, 0.66993],
  ["C", 0, 0.86841, 0, 1.08849, 0, 1.52866],
];

registerPaint("bubble", class {
  static get inputProperties() { return ["--bubble-color", "--bubble-tail"]; }
  paint(ctx, size, props) {
    const tail = String(props.get("--bubble-tail")).trim() === "1";
    const W = size.width, H = size.height - (tail ? TAIL : 0);
    const pill = H / 2 <= 18;
    const r = Math.min(17, H / 2 / 1.52866); // continuous corner: the turn spans 1.53r of each edge
    // corner(map) walks one corner clockwise; map takes (along, into) in px and returns canvas xy.
    const corner = (map, first) => {
      for (const [op, ...n] of CORNER) {
        const p = []; for (let i = 0; i < n.length; i += 2) p.push(...map(n[i] * r, n[i + 1] * r));
        if (op === "M") first ? ctx.moveTo(...p) : ctx.lineTo(...p);
        else if (op === "L") ctx.lineTo(...p);
        else ctx.bezierCurveTo(...p);
      }
    };
    ctx.fillStyle = String(props.get("--bubble-color")).trim() || "#000";
    ctx.beginPath();
    if (pill) {
      const R = H / 2;
      ctx.moveTo(R, 0);
      ctx.lineTo(W - R, 0);
      if (tail) {
        // Right cap down to where the tail peels off.
        ctx.arc(W - R, R, R, -Math.PI / 2, TAIL_FROM);
      } else ctx.arc(W - R, R, R, -Math.PI / 2, Math.PI / 2);
    } else {
      ctx.moveTo(1.52866 * r, 0);
      corner((p, q) => [W - p, q], true);                        // top-right
      if (!tail) corner((p, q) => [W - q, H - p]);                // bottom-right
      else { ctx.lineTo(W, H - PILL); ctx.arc(W - PILL, H - PILL, PILL, 0, TAIL_FROM); }
    }
    if (tail) {
      // Fitted to the anti-aliased edge of her iMessage shot (work/w/fit.py, RMS 0.2px); G1 at every joint:
      // the cap's arc hands its tangent to the outer edge, the tip turns smoothly, the inner edge lands flat on the bottom.
      const k = pill ? H / 2 / PILL : 1; // a pill whose cap isn't 16.25 scales the tail with it, so the joint stays on the arc
      const X = (dx) => W + dx * k, Y = (dy) => H + dy * k;
      ctx.bezierCurveTo(X(-9.373), Y(-1.108), X(-8.851), Y(1.012), X(-7.346), Y(3.429)); // outer edge, S-curve out of the cap
      ctx.bezierCurveTo(X(-6.828), Y(4.261), X(-6.263), Y(5.561), X(-7.717), Y(5.393));  // tip
      ctx.bezierCurveTo(X(-10.38), Y(5.085), X(-15.811), Y(0), X(-17.739), Y(0));        // inner edge into the bottom
    }
    if (pill) {
      const R = H / 2;
      ctx.lineTo(R, H);
      ctx.arc(R, R, R, Math.PI / 2, (3 * Math.PI) / 2);
    } else {
      corner((p, q) => [p, H - q]);                               // bottom-left
      corner((p, q) => [q, p]);                                   // top-left
    }
    ctx.closePath();
    ctx.fill();
  }
});
