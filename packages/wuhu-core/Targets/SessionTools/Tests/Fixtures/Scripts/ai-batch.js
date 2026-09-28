import { generateImage } from "wuhu:ai"

const destinations = ["/art/moon.png", "/art/sun.png", "/art/comet.png", "/art/star.png", "/art/nebula.png", "machines://mc_aaaaaaaa/tmp/void.png"]
const images = await Promise.all(destinations.map((destination) => generateImage(destination.split("/").pop().slice(0, -4), { destination })))
result(images)
