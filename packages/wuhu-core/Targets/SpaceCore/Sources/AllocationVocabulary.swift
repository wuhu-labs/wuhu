import Crypto
import Foundation

// Frozen once the first allocation exists: names are positional encodings over
// this exact list, so any edit after that breaks every issued name. The
// allocation_freeze row pins the digest and allocate() refuses on mismatch.
// Exactly 256 words, so every stratum is a power-of-two Feistel domain.
enum AllocationVocabulary {
  static let words: [String] = [
    "anchor", "apple", "arctic", "arrow", "autumn", "bacon", "badge", "ball", "bamboo", "banana",
    "barrel", "basket", "beach", "bean", "bike", "bird", "blade", "blue", "boat", "book", "brave",
    "bread", "breeze", "bright", "broom", "brown", "brush", "bulb", "butter", "cabin", "cable",
    "cake", "calm", "camera", "candy", "canoe", "canvas", "canyon", "carpet", "celery", "cereal",
    "chair", "chalk", "cheese", "cherry", "clever", "cliff", "clock", "cloud", "coast", "coffee",
    "coral", "corn", "cotton", "couch", "coyote", "cradle", "crane", "crater", "cream", "creek",
    "crisp", "cube", "dawn", "deer", "desert", "donkey", "dove", "drum", "duck", "dune", "eager",
    "eagle", "earth", "engine", "fence", "field", "fish", "flag", "forest", "fork", "frame",
    "frog", "frost", "gadget", "galaxy", "garden", "garlic", "gate", "gentle", "giant", "ginger",
    "glove", "goat", "goose", "grape", "grass", "green", "guitar", "hammer", "happy", "hawk",
    "helmet", "hill", "honey", "horse", "island", "ivory", "jacket", "jaguar", "juice", "kite",
    "kitten", "kiwi", "ladder", "lake", "lamp", "laptop", "lava", "lemon", "lens", "lion",
    "lizard", "lucky", "lunar", "magnet", "mango", "maple", "marble", "marine", "meadow", "merry",
    "milk", "mirror", "monkey", "moon", "mouse", "muffin", "mule", "napkin", "noodle", "ocean",
    "olive", "onion", "orange", "orbit", "oven", "oyster", "ozone", "paddle", "panda", "parrot",
    "peanut", "pencil", "pepper", "piano", "pigeon", "pilot", "pink", "pipe", "pizza", "planet",
    "plate", "polar", "pond", "pony", "potato", "puppy", "puzzle", "quick", "rabbit", "radar",
    "radio", "rain", "rally", "raven", "ribbon", "rice", "ridge", "river", "robot", "rocket",
    "roof", "saddle", "sail", "salad", "salmon", "salt", "sand", "sauce", "season", "shell",
    "shield", "ship", "shoe", "shrimp", "smooth", "snake", "snow", "sock", "solar", "speed",
    "spice", "spider", "spoon", "spring", "stamp", "stove", "sugar", "summer", "sunny", "sunset",
    "swamp", "swift", "syrup", "table", "tape", "tent", "ticket", "tide", "tiger", "timber",
    "tiny", "toast", "tomato", "torch", "tower", "track", "train", "tray", "truck", "tube", "tuna",
    "tunnel", "turkey", "turtle", "valley", "velvet", "violin", "vivid", "wagon", "walnut", "warm",
    "wasp", "wave", "weasel", "whale", "wheat", "wheel", "window", "winter", "wire", "wise",
    "wolf", "yellow", "zebra",
  ]

  static let digest: String = hexEncoded(
    SHA256.hash(data: Data(words.joined(separator: "\n").utf8)),
  )
}
