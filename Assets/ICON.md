# App icon

The original flat photographic iPod PNG from the website (`site/img/cardsdecks-device.png`), preserved as `iPod-Website.png`. No generated hardware. `make-icon.swift` scales it proportionally onto a transparent square canvas; sips and iconutil produce the macOS icon sizes.

The screen is cropped from the iOS 4-era Home screen image archived at https://theapplewiki.com/wiki/File:IPod_touch_(4th_generation).png (2012 archived revision of Apple’s original product image, with earphones removed by Dialexio). Original downloaded file: `iPod-Home-Reference.png`. Source file: https://theapplewiki.com/images/applewiki/archive/4/4c/20130610003936%21IPod_touch_%284th_generation%29.png

Only the screen rectangle is composited; the site's existing photographic body is retained. Apple imagery remains its respective owner's material, not newly generated artwork.

## Mirror composition

The current icon adds a polished mirror behind the unchanged photographic iPod, with a low-opacity horizontally flipped copy as its reflection. `compose-mirror.swift` uses `iPod-Flat.png` (the prior flat icon) and `Mirror-Backdrop.png` to produce `AppIcon-Mirror.png`, copied to `AppIcon.png` for packaging.

The mirror backdrop alone was generated with the built-in image-generation tool. Prompt: Create a transparent-background Mac OS X Snow Leopard utility-icon backdrop: a polished silver-framed freestanding mirror in slight three-quarter perspective, dark desaturated blue-gray reflective glass, narrow beveled chrome rim, restrained studio highlights, subtle shadow. No iPod, phone, device, UI, text, logos, arrows, or enclosing icon tile. The real hardware is composited afterward without generation.
