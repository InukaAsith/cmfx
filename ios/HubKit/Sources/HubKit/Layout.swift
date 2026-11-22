import Foundation

/// Page view, drawn: the phone's browser lays the page out, this reads where everything landed (boxes, borders, text
/// lines with their colour and weight, images), and the watch draws the site as it is, in its own font
/// (cmf-watch-sdk browser long.rs). A "fancy" page (mostly pictures, a canvas, a video wall, too little text) is sent
/// as a picture instead (Rle.longPicture).
public enum Layout {
    /// Reads the page laid out `width` × `height` CSS px (from its top): JSON (see `Read`).
    public static func script(width: Double, height: Double) -> String {
        """
        (() => { const W = \(width), H = \(height);
          const col = s => { const m = /rgba?\\(([^)]+)\\)/.exec(s || ''); if (!m) return null;
            const p = m[1].split(/[ ,\\/]+/).filter(x => x).map(Number); return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]; };
          const bgs = new Map();
          const under = e => { for (; e; e = e.parentElement) { if (bgs.has(e)) return bgs.get(e);
              const c = col(getComputedStyle(e).backgroundColor); if (c && c[3] > 0.5) { bgs.set(e, c); return c; } }
            return [255, 255, 255, 1]; };
          const box = r => [r.left, r.top + scrollY, r.width, r.height];
          const out = { bg: under(document.body), boxes: [], frames: [], texts: [], imgs: [], canvas: 0, img: 0, video: 0, chars: 0 };
          const seen = (r) => r.width >= 2 && r.height >= 2 && r.bottom > 0 && r.top + scrollY < H && r.right > 0 && r.left < W;
          for (const e of document.body.querySelectorAll('*')) {
            const tag = e.tagName.toLowerCase();
            if (['script', 'style', 'noscript', 'template', 'head'].includes(tag) || e.closest('svg') && tag != 'svg') continue;
            const r = e.getBoundingClientRect(); if (!seen(r)) continue;
            const st = getComputedStyle(e);
            if (st.visibility == 'hidden' || st.display == 'none' || +st.opacity < 0.1) continue;
            const area = Math.min(r.width, W) * Math.min(r.height, H);
            if (tag == 'canvas' || tag == 'video' || tag == 'iframe') { out[tag == 'video' ? 'video' : 'canvas'] += area; out.imgs.push(box(r)); continue; }
            if ((tag == 'input' && !['button','submit','checkbox','radio','image','reset','hidden','range','color','file'].includes((e.type || '').toLowerCase())) || tag == 'textarea') {
              const v = (e.value || e.placeholder || '').trim();
              if (v) { const c = col(e.value ? st.color : '') || (e.value ? [0, 0, 0, 1] : [128, 128, 128, 1]);
                const pl = parseFloat(st.paddingLeft) || 0;
                out.texts.push([r.left + pl, r.top + scrollY, Math.max(10, r.width - pl), r.height, c[0], c[1], c[2], 0, v.slice(0, 80)]); out.chars += v.length; }
            }
            if (tag == 'img' || tag == 'svg' || tag == 'picture') { if (tag != 'picture') { out.img += area; out.imgs.push(box(r)); } continue; }
            const bi = st.backgroundImage;
            if (bi && bi.includes('url(') && r.width * r.height > 64) { out.img += area; out.imgs.push(box(r)); }
            const c = col(st.backgroundColor);
            if (c && c[3] > 0.5) { const p = under(e.parentElement);
              if (Math.abs(c[0] - p[0]) + Math.abs(c[1] - p[1]) + Math.abs(c[2] - p[2]) > 6)
                out.boxes.push([...box(r), c[0], c[1], c[2], parseFloat(st.borderTopLeftRadius) || 0, p[0], p[1], p[2]]); }
            const bw = parseFloat(st.borderTopWidth) || 0;
            if (bw >= 1 && st.borderTopStyle != 'none' && parseFloat(st.borderBottomWidth) >= 1 && parseFloat(st.borderLeftWidth) >= 1) {
              const bc = col(st.borderTopColor); if (bc && bc[3] > 0.3) out.frames.push([...box(r), bc[0], bc[1], bc[2]]); }
            else if (parseFloat(st.borderBottomWidth) >= 1 && st.borderBottomStyle != 'none') {
              const bc = col(st.borderBottomColor); if (bc && bc[3] > 0.3) out.boxes.push([r.left, r.bottom + scrollY - 1, r.width, 1, bc[0], bc[1], bc[2], 0, 0, 0, 0]); }
          }
          const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), rg = document.createRange(), styles = new Map();
          let words = 0, n;
          while ((n = tw.nextNode()) && words < 6000) {
            const t = n.data; if (!t.trim()) continue;
            const el = n.parentElement; if (!el || el.closest('script,style,noscript,svg,template')) continue;
            let s = styles.get(el);
            if (!s) { const st = getComputedStyle(el), er = el.getBoundingClientRect();
              // screen-reader-only text (a pixel big, clipped to nothing) is not on the page
              const hidden = er.width <= 2 || er.height <= 2 || (st.clip || '').startsWith('rect(0') || (st.clipPath || '').startsWith('inset(50%')
                || (st.position == 'absolute' && st.overflow == 'hidden' && (er.width <= 3 || er.height <= 3));
              s = { ok: !hidden && st.visibility != 'hidden' && (!el.checkVisibility || el.checkVisibility({ opacityProperty: true, visibilityProperty: true })),
                    c: col(st.color) || [0, 0, 0, 1], b: (parseInt(st.fontWeight) || 400) >= 600 ? 1 : 0,
                    u: (st.textDecorationLine || '').includes('underline') ? 2 : 0 };
              styles.set(el, s); }
            if (!s.ok || s.c[3] < 0.2) continue;
            const re = /\\S+/g; let m, line = null;
            const flush = () => { if (line && line.right > 0 && line.left < W && line.top + scrollY < H) {
                out.texts.push([line.left, line.top + scrollY, line.right - line.left, line.bottom - line.top, s.c[0], s.c[1], s.c[2], s.b | s.u, line.text]);
                out.chars += line.text.length; } };
            while ((m = re.exec(t)) && words < 6000) {
              words++;
              rg.setStart(n, m.index); rg.setEnd(n, m.index + m[0].length);
              const r = rg.getBoundingClientRect(); if (r.width == 0 || r.height == 0) continue;
              if (line && Math.abs(r.top - line.top) < 3 && r.left >= line.right - 2) { line.text += ' ' + m[0]; line.right = r.right; line.bottom = Math.max(line.bottom, r.bottom); }
              else { flush(); line = { left: r.left, top: r.top, right: r.right, bottom: r.bottom, text: m[0] }; }
            }
            flush();
          }
          return JSON.stringify(out); })()
        """
    }

    struct Read: Decodable {
        let bg: [Double]
        let boxes: [[Double]]
        let frames: [[Double]]
        let texts: [[Value]]
        let imgs: [[Double]]
        let canvas: Double, img: Double, video: Double, chars: Int
    }

    enum Value: Decodable {
        case n(Double), s(String)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .n(v) } else { self = .s(try c.decode(String.self)) }
        }
        var n: Double { if case .n(let v) = self { return v }; return 0 }
        var s: String { if case .s(let v) = self { return v }; return "" }
    }

    /// A page the watch can't draw as it is: mostly pictures (a feed), a canvas or a video (a map, an app), or next
    /// to no text.
    static func fancy(_ r: Read, width: Double, height: Double) -> Bool {
        let area = width * height
        return r.chars < 40 || r.canvas + r.video > 0.3 * area || r.img > 0.6 * area
    }

    /// The page drawn: `J h`, per slab of the page (one watch screen) its boxes, its images (cut out of `rgb`, the
    /// page's picture `pw` px wide), its text, as `o`/`p` ops and `I`/`D`/`E` bands; `j`. Nil: a fancy page (send
    /// its picture). `cssWidth` / `cssHeight` the page as laid out; `cap` what the watch keeps.
    public static func messages(json: String, rgb: [UInt8], pw: Int, ph: Int, cssWidth: Double, cssHeight: Double,
                                cap: Int = 55 * 1024, imageCap: Int = 22 * 1024) -> (messages: [Data], height: Int)? {
        guard let r = try? JSONDecoder().decode(Read.self, from: Data(json.utf8)),
              !fancy(r, width: cssWidth, height: cssHeight) else { return nil }
        let k = 466 / cssWidth
        let px = Double(pw) / cssWidth
        func c565(_ a: Double, _ b: Double, _ c: Double) -> UInt16 {
            Rle.rgb565(UInt8(clamping: Int(a)), UInt8(clamping: Int(b)), UInt8(clamping: Int(c)))
        }
        struct Op { let top: Int; let bottom: Int; let bytes: Data }
        /// Characters the watch's font lacks, as ones it has.
        func watchText(_ s: String) -> String {
            var t = s
            for (a, b) in [("\u{00B7}", "-"), ("\u{2022}", "-"), ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2019}", "'"),
                           ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{00A0}", " "), ("\u{203A}", ">"), ("\u{2039}", "<")] {
                t = t.replacingOccurrences(of: a, with: b)
            }
            return t
        }
        var under: [Op] = [], text: [Op] = []
        var images: [(top: Int, bottom: Int, x: Int, y: Int, w: Int, h: Int)] = []
        // the page's own colour first, all of it
        let page = Int(cssHeight * k)
        do {
            var d = Data([UInt8(ascii: "r")])
            d.le(Int16(0)); d.le(UInt16(0)); d.le(UInt16(466)); d.le(UInt16(clamping: page))
            d.le(c565(r.bg[0], r.bg[1], r.bg[2])); d.le(UInt16(0)); d.append(0)
            under.append(Op(top: 0, bottom: page, bytes: d))
        }
        for b in r.boxes where b.count == 11 {
            let (x, y, w, h) = (Int(b[0] * k), Int(b[1] * k), max(1, Int(b[2] * k)), max(1, Int(b[3] * k)))
            var d = Data([UInt8(ascii: "r")])
            d.le(Int16(clamping: x)); d.le(UInt16(clamping: y)); d.le(UInt16(clamping: w)); d.le(UInt16(clamping: h))
            d.le(c565(b[4], b[5], b[6])); d.le(c565(b[8], b[9], b[10])); d.append(UInt8(clamping: Int(b[7] * k)))
            under.append(Op(top: y, bottom: y + h, bytes: d))
        }
        for f in r.frames where f.count == 7 {
            let (x, y, w, h) = (Int(f[0] * k), Int(f[1] * k), max(4, Int(f[2] * k)), max(4, Int(f[3] * k)))
            var d = Data([UInt8(ascii: "f")])
            d.le(Int16(clamping: x)); d.le(UInt16(clamping: y)); d.le(UInt16(clamping: w)); d.le(UInt16(clamping: h))
            d.le(c565(f[4], f[5], f[6]))
            under.append(Op(top: y, bottom: y + h, bytes: d))
        }
        for t in r.texts where t.count == 9 {
            let (x, top, w, h) = (Int(t[0].n * k), t[1].n * k, Int(t[2].n * k), t[3].n * k)
            // the watch's 21 px line in the middle of the page's
            let y = Int(top + h / 2) - 11
            let s = utf8(watchText(t[8].s), 100)
            // the watch's font runs a little wider than a page's: room to the screen's edge, a quarter more at most
            let room = min(w + w / 4 + 8, max(w + 8, 466 - x))
            var d = Data([UInt8(ascii: "t")])
            d.le(Int16(clamping: x)); d.le(UInt16(clamping: max(0, y))); d.le(UInt16(clamping: room))
            d.le(c565(t[4].n, t[5].n, t[6].n)); d.append(UInt8(clamping: Int(t[7].n))); d.append(UInt8(s.count)); d.append(s)
            text.append(Op(top: y, bottom: y + 24, bytes: d))
        }
        for i in r.imgs where i.count == 4 && i[2] >= 10 && i[3] >= 10 {
            let (x, y, w, h) = (Int(i[0] * k), Int(i[1] * k), Int(i[2] * k), Int(i[3] * k))
            images.append((y, y + h, x, y, w, h))
        }
        images.sort { $0.top < $1.top }

        let slab = 466
        var out: [Data] = []
        var used = 0, imageBytes = 0, height = 0
        var slabTop = 0
        func put(_ ops: [Op], into out: inout [Data], text: Bool = false) -> Int {
            guard !ops.isEmpty else { return 0 }
            var m = Data([UInt8(ascii: "o")])
            m.le(UInt16(clamping: ops.map(\.top).min()!))
            m.le(UInt16(clamping: ops.map(\.bottom).max()!))
            m.append(text ? 1 : 0)
            out.append(m)
            var p = Data([UInt8(ascii: "p")]), n = 0
            for o in ops {
                if p.count + o.bytes.count > 127 {
                    out.append(p)
                    p = Data([UInt8(ascii: "p")])
                }
                p += o.bytes
                n += o.bytes.count
            }
            if p.count > 1 { out.append(p) }
            return n
        }
        while slabTop < page {
            let slabEnd = min(slabTop + slab, page)
            let inSlab = { (o: Op) in o.top >= slabTop && o.top < slabEnd }
            var part: [Data] = []
            var size = put(under.filter(inSlab), into: &part)
            for im in images where im.top >= slabTop && im.top < slabEnd {
                // cut out of the page's picture, 2 px a pixel, its own 16 colours
                let (x0, y0) = (max(0, Int(Double(im.x) / k * px)), max(0, Int(Double(im.y) / k * px)))
                let x1 = min(pw, Int(Double(im.x + im.w) / k * px)), y1 = min(ph, Int(Double(im.y + im.h) / k * px))
                guard x1 - x0 >= 3, y1 - y0 >= 3 else { continue }
                var crop = [UInt8](); crop.reserveCapacity((x1 - x0) * (y1 - y0) * 3)
                for yy in y0..<y1 { crop += rgb[(3 * (yy * pw + x0))..<(3 * (yy * pw + x1))] }
                let (palette, idx) = Quantize.refined(rgb: crop, colours: 16)
                let pal = (palette + Array(repeating: (0, 0, 0), count: max(0, 16 - palette.count))).prefix(16).map { Rle.rgb565($0.0, $0.1, $0.2) }
                let tok = Rle.tokens(idx, width: x1 - x0, height: y1 - y0)
                let hdr = Rle.header(width: x1 - x0, height: y1 - y0, scale: 2, x0: Int16(clamping: x0 * 2),
                                     y0: Int16(clamping: y0 * 2), palette: pal)
                if imageBytes + hdr.count + tok.count > imageCap {
                    // over the images' share: a grey box where it is
                    var d = Data([UInt8(ascii: "r")])
                    d.le(Int16(clamping: im.x)); d.le(UInt16(clamping: im.y)); d.le(UInt16(clamping: im.w)); d.le(UInt16(clamping: im.h))
                    d.le(Rle.rgb565(0xD0, 0xD0, 0xD0)); d.le(UInt16(0)); d.append(0)
                    size += put([Op(top: im.y, bottom: im.y + im.h, bytes: d)], into: &part)
                    continue
                }
                imageBytes += hdr.count + tok.count
                size += hdr.count + tok.count
                part += Rle.messages(header: hdr, tokens: tok)
            }
            size += put(text.filter(inSlab), into: &part, text: true)
            guard used + size <= cap else { break }
            used += size
            out += part
            height = slabEnd
            slabTop = slabEnd
        }
        var j = Data([UInt8(ascii: "J")])
        j.le(UInt16(clamping: height))
        return ([j] + out + [Data([UInt8(ascii: "j")])], height)
    }
}
