r"""A short history for every system in the maker menus (James 2026-11-26: "would love history on each system too").

Writes collections\<maker>\medium_artwork\am_story\<system>.txt - the same panel the ArcadeMaster layout shows for a
game after a few seconds at rest (am_story), so resting on a system tile tells its story. Well-known facts only.
  python tools/New-SystemStories.py --retrofe R:/ArcadeMaster/frontend/LEGENDS-am
"""
import argparse
import os
import re

MAKERS = ["Nintendo", "Sega", "Sony", "Microsoft", "Atari", "NEC", "SNK", "Computers", "Arcade Boards", "Other Systems"]

# name -> (heading, history, [what made it special])
STORIES = {
    "game boy": ("Game Boy (Nintendo, 1989)", "Gunpei Yokoi's handheld: a monochrome screen, four AA batteries and almost unbreakable.",
                 ["Launched with Tetris, which sold the machine to adults as well as children.", "Pokemon Red and Green (1996) began here.", "With Game Boy Color, well over 100 million sold."]),
    "game boy color": ("Game Boy Color (Nintendo, 1998)", "The Game Boy in colour, still playing the old cartridges.",
                       ["Most original Game Boy games run on it, some with added colour.", "Home of Pokemon Gold and Silver and The Legend of Zelda: Link's Awakening DX."]),
    "game boy advance": ("Game Boy Advance (Nintendo, 2001)", "A 32-bit handheld with roughly Super Nintendo power in your pocket.",
                         ["Plays Game Boy and Game Boy Color cartridges too.", "Many Super Nintendo classics were brought to it.", "Over 80 million sold."]),
    "nintendo entertainment system - famicom": ("Nintendo Entertainment System / Famicom (Nintendo, 1983)", "Released as the Famicom in Japan in 1983 and as the NES in North America in 1985, after the 1983 video game crash.",
                                                ["Brought home video games back in North America.", "Super Mario Bros., The Legend of Zelda and Metroid started here.", "Nintendo's seal of quality and licensing rules shaped the console business."]),
    "super nintendo entertainment system": ("Super Nintendo (Nintendo, 1990)", "Nintendo's 16-bit console: the Super Famicom in Japan in 1990, the SNES in North America in 1991.",
                                            ["Mode 7 scaling and rotation (F-Zero, Super Mario Kart).", "The Super FX chip put 3D polygons in a cartridge (Star Fox).", "Super Metroid, Chrono Trigger and A Link to the Past are among its classics."]),
    "nintendo 64": ("Nintendo 64 (Nintendo, 1996)", "Nintendo's first 3D console, which stayed with cartridges when CDs took over.",
                    ["Its analog stick shaped 3D controls ever since.", "Super Mario 64 and Ocarina of Time set the rules for 3D games.", "Four controller ports: GoldenEye 007 and Mario Kart 64 made it a party machine."]),
    "gamecube": ("GameCube (Nintendo, 2001)", "A compact, powerful console that played small 8 cm optical discs.",
                 ["Super Smash Bros. Melee is still played competitively today.", "Metroid Prime and The Wind Waker came out on it."]),
    "nintendo ds": ("Nintendo DS (Nintendo, 2004)", "Two screens, one of them a touch screen, plus a microphone.",
                    ["Brain Age and Nintendogs reached people who had never played games.", "Over 150 million sold, one of the best-selling consoles ever."]),
    "nintendo 3ds": ("Nintendo 3DS (Nintendo, 2011)", "The DS's two screens, with 3D on the top one and no glasses needed.",
                     ["Super Mario 3D Land and Pokemon X and Y made full use of the 3D screen.", "It also plays the whole DS library.", "Over 75 million sold across the 3DS family."]),
    "wii": ("Wii (Nintendo, 2006)", "Motion controls with a pointing remote brought whole families to video games.",
            ["Wii Sports came in the box in most regions and became a phenomenon.", "Over 100 million sold."]),
    "wii u": ("Wii U (Nintendo, 2012)", "A console whose controller had its own screen, the forerunner of the Switch.",
              ["Mario Kart 8, Super Smash Bros. and Splatoon first appeared here.", "Many of its games were later brought to the Switch."]),
    "switch": ("Nintendo Switch (Nintendo, 2017)", "A home console you take with you: dock it on the TV or play it in your hands.",
               ["Detachable Joy-Con controllers for two players anywhere.", "The Legend of Zelda: Breath of the Wild launched with it.", "Among the best-selling consoles of all time."]),
    "sg-1000": ("SG-1000 (Sega, 1983)", "Sega's first home console, released in Japan the same day as Nintendo's Famicom.",
                ["The start of Sega's hardware line that led to the Master System."]),
    "master system - mark iii": ("Master System / Mark III (Sega, 1985)", "Sega's 8-bit console, the Mark III in Japan and the Master System in the West.",
                                 ["Hugely popular in Europe and Brazil, where it was made for decades.", "Home of Alex Kidd and the early Phantasy Star."]),
    "megadrive - genesis": ("Mega Drive / Genesis (Sega, 1988)", "Sega's 16-bit console: the Mega Drive in Japan and Europe, the Genesis in North America.",
                            ["Sonic the Hedgehog (1991) made Sega Nintendo's equal.", "Fast arcade-style games and the 'Genesis does what Nintendon't' era.", "Around 30 million sold."]),
    "32x": ("32X (Sega, 1994)", "An add-on that plugged into the Mega Drive / Genesis to give it 32-bit power.",
            ["Short-lived: the Saturn came out only months later.", "Virtua Racing Deluxe and Knuckles' Chaotix are its best-known games."]),
    "game gear": ("Game Gear (Sega, 1990)", "Sega's colour handheld, essentially a portable Master System with a backlit screen.",
                  ["A colour screen against the Game Boy's monochrome one, at the cost of battery life."]),
    "saturn": ("Saturn (Sega, 1994)", "Sega's 32-bit CD console, with two main processors.",
               ["Strong in Japan, with excellent 2D fighting and shooting games.", "Panzer Dragoon, NiGHTS into Dreams and Virtua Fighter 2."]),
    "dreamcast": ("Dreamcast (Sega, 1998)", "Sega's last console, and the first with a built-in modem for online play.",
                  ["Shenmue, Jet Set Radio, Soulcalibur and Crazy Taxi.", "Its VMU memory card had its own small screen.", "Sega stopped making consoles in 2001, but its arcade board (NAOMI) is close kin."]),
    "playstation": ("PlayStation (Sony, 1994)", "Sony's first console, which began as a CD add-on for the Super Nintendo.",
                    ["CDs made games cheaper to make and held full-motion video.", "Final Fantasy VII, Metal Gear Solid and Gran Turismo.", "Over 100 million sold."]),
    "playstation 2": ("PlayStation 2 (Sony, 2000)", "Sony's second console, which also played DVDs.",
                      ["The best-selling home console of all time, over 150 million.", "Grand Theft Auto: San Andreas, Shadow of the Colossus and God of War."]),
    "playstation portable": ("PlayStation Portable (Sony, 2004)", "Sony's handheld, with a wide screen and UMD optical discs.",
                             ["Near PlayStation 2 graphics in your hand.", "Monster Hunter Freedom made it huge in Japan."]),
    "xbox": ("Xbox (Microsoft, 2001)", "Microsoft's first console, built much like a PC, with a hard drive inside.",
             ["Halo: Combat Evolved defined console shooters.", "Xbox Live (2002) made online console play mainstream."]),
    "xbox 360": ("Xbox 360 (Microsoft, 2005)", "Microsoft's second console, the start of HD console gaming.",
                 ["Achievements and Xbox Live Arcade.", "Gears of War, Halo 3 and the Kinect camera."]),
    "atari 2600": ("Atari 2600 (Atari, 1977)", "The console that brought cartridge games into homes around the world.",
                   ["Its joystick became the symbol of video games.", "Activision, the first third-party game maker, was founded by Atari programmers.", "Space Invaders, Pitfall! and Adventure."]),
    "atari 5200": ("Atari 5200 (Atari, 1982)", "Atari's more powerful follow-up to the 2600, based on its 8-bit home computers.",
                   ["An analog joystick, with a keypad, years before analog sticks were common."]),
    "atari 7800": ("Atari 7800 (Atari, 1986)", "Atari's 8-bit console, which also played almost every 2600 cartridge.",
                   ["Its MARIA graphics chip could move many sprites at once."]),
    "lynx": ("Atari Lynx (Atari, 1989)", "The first handheld with a colour backlit screen.",
             ["Hardware sprite scaling, and you could flip it for left-handed play.", "Developed with Epyx, the makers of California Games."]),
    "jaguar": ("Atari Jaguar (Atari, 1993)", "Atari's last console, sold as the first 64-bit system.",
               ["Alien vs Predator and Tempest 2000 are its standouts.", "A controller with a 12-key keypad."]),
    "jaguar cd": ("Atari Jaguar CD (Atari, 1995)", "A CD drive add-on that sat on top of the Jaguar.",
                  ["One of the last pieces of hardware Atari released."]),
    "pc engine": ("PC Engine / TurboGrafx-16 (NEC and Hudson Soft, 1987)", "A small console with an 8-bit processor and 16-bit graphics, on credit-card-sized HuCards.",
                  ["For a while it outsold Nintendo's Famicom in Japan.", "A favourite for shooting games such as R-Type."]),
    "pc engine cd": ("PC Engine CD (NEC, 1988)", "A CD-ROM drive for the PC Engine, the first CD add-on for a game console.",
                     ["CD audio soundtracks and voiced cut-scenes years before most consoles.", "Ys Book I & II and Rondo of Blood."]),
    "supergrafx": ("SuperGrafx (NEC, 1989)", "An upgraded PC Engine with twice the graphics hardware.",
                   ["Only a handful of games used its extra power, Ghouls 'n Ghosts among them."]),
    "neo geo": ("Neo Geo (SNK, 1990)", "SNK's arcade board, the MVS, and the home console version, the AES, ran the very same games.",
                ["Real arcade games at home, at a famously high price.", "The King of Fighters, Metal Slug and Samurai Shodown.", "SNK made new MVS games until 2004."]),
    "neo geo pocket": ("Neo Geo Pocket (SNK, 1998)", "SNK's monochrome handheld, replaced within a year by the colour model.",
                       ["A clicky micro-switched stick, great for fighting games."]),
    "neo geo pocket color": ("Neo Geo Pocket Color (SNK, 1999)", "SNK's colour handheld with its excellent clicking stick.",
                             ["SNK vs. Capcom: Match of the Millennium and Metal Slug: 1st Mission."]),
    "amiga ocsecs": ("Amiga (Commodore, 1985)", "Commodore's 16-bit home computer, years ahead in graphics and sound.",
                     ["Custom chips for graphics and four-channel sampled sound.", "Lemmings, The Secret of Monkey Island and Sensible Soccer.", "Created the 'demoscene' in Europe."]),
    "commodore 64": ("Commodore 64 (Commodore, 1982)", "The best-selling single home computer model ever, with millions sold.",
                     ["The SID sound chip gave it some of the most loved music in gaming.", "Cassettes and floppy disks; type LOAD and wait."]),
    "zx spectrum": ("ZX Spectrum (Sinclair Research, 1982)", "Sir Clive Sinclair's small rubber-keyed computer that started Britain's game industry.",
                    ["Bedroom programmers became studios (Ultimate, later Rare).", "Manic Miner, Jet Set Willy and Knight Lore."]),
    "atomiswave": ("Atomiswave (Sammy, 2003)", "Sammy's arcade board, based on Sega's Dreamcast and NAOMI hardware.",
                   ["Cheap cartridges kept it in arcades: Metal Slug 6, The King of Fighters XI."]),
    "final burn": ("FinalBurn Neo (arcade emulator)", "The open emulator for classic arcade boards: Capcom CPS-1/2/3, Neo Geo, Konami and many more.",
                   ["Fast and accurate, and it runs well on modest hardware.", "Netplay and save states for arcade classics."]),
    "model 2": ("Sega Model 2 (Sega, 1993)", "Sega's arcade 3D board with texture-mapped polygons.",
                ["Daytona USA, Virtua Fighter 2 and The House of the Dead.", "It set the standard for arcade 3D in the mid-1990s."]),
    "model 3": ("Sega Model 3 (Sega, 1996)", "Sega's next arcade board, far beyond the home consoles of its day.",
                ["Scud Race, Virtua Fighter 3 and Sega Rally 2."]),
    "naomi": ("Sega NAOMI (Sega, 1998)", "Sega's arcade board, closely related to the Dreamcast.",
              ["Crazy Taxi, Marvel vs. Capcom 2 and Ikaruga started here.", "Many games came home to the Dreamcast almost unchanged."]),
    "teknoparrot": ("TeknoParrot (modern arcade games)", "Runs arcade games that run on PC-based boards (Sega Lindbergh and RingEdge, Taito Type X, Namco System ES) on a Windows PC.",
                    ["After Burner Climax, Pokken Tournament, Blade Strangers and Initial D.", "The newest generation of arcade cabinets, at home."]),
    "3do": ("3DO Interactive Multiplayer (1993)", "A console standard made by Panasonic, Goldstar and Sanyo under licence, led by EA founder Trip Hawkins.",
            ["One of the first CD-based consoles.", "Road Rash and Gex were among its games."]),
    "colecovision": ("ColecoVision (Coleco, 1982)", "A console famous for near-arcade versions of arcade games.",
                     ["Came bundled with Donkey Kong.", "An adapter let it play Atari 2600 cartridges."]),
    "atari 800": ("Atari 400 / 800 (Atari, 1979)", "Atari's first home computers, designed by much of the team that built the 2600.",
                  ["Custom graphics and sound chips, later reused in the Atari 5200.", "Star Raiders showed what a home computer game could be."]),
    "neo geo cd": ("Neo Geo CD (SNK, 1994)", "The Neo Geo's arcade games on CD, at a fraction of the cartridge price.",
                   ["Same games as the arcade board, with long loading times on the early model."]),
    "amstrad cpc": ("Amstrad CPC (Amstrad, 1984)", "Alan Sugar's all-in-one home computer, sold with its own monitor and tape or disk drive.",
                    ["Big in the UK, France and Spain.", "Many Spectrum games were brought to it with more colour."]),
    "msx": ("MSX (Microsoft and ASCII, 1983)", "A shared home-computer standard built by many makers - Sony, Panasonic, Philips and more.",
            ["Konami's early Metal Gear and many Konami classics started here.", "Popular in Japan, Europe, Brazil and the Middle East."]),
    "msx2": ("MSX2 (1985)", "The second MSX generation, with far better graphics.",
             ["Metal Gear (1987) and Space Manbow.", "Still runs most first-generation MSX software."]),
    "ports": ("Ports", "Classic games rebuilt to run natively, from their released source code or by their fans.",
              ["Doom, Quake and others running as native PC programs, not emulated."]),
}


def text(heading, body, special):
    return heading + "\n\n" + body + "\n\nWHAT MADE IT SPECIAL\n" + "\n".join("- " + s for s in special) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrofe", required=True)
    a = ap.parse_args()
    cols = os.path.join(a.retrofe, "collections")
    made, missing = 0, []
    for maker in MAKERS:
        mt = os.path.join(cols, maker, "menu.txt")
        if not os.path.exists(mt):
            continue
        out = os.path.join(cols, maker, "medium_artwork", "am_story")
        os.makedirs(out, exist_ok=True)
        for system in [l.strip() for l in open(mt) if l.strip()]:
            key = re.sub(r"\s*\(retrobat\)\s*$", "", system.lower()).strip()
            st = STORIES.get(key)
            if not st:
                missing.append(system)
                continue
            with open(os.path.join(out, system + ".txt"), "w", encoding="utf-8") as f:
                f.write(text(*st))
            made += 1
    print("system stories: %d written%s" % (made, (", none for: " + ", ".join(missing)) if missing else ""))


if __name__ == "__main__":
    main()
