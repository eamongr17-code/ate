// supabase/staging-seed/data.mjs — the vocabulary the round-6 staging dataset is drawn from:
// the cities' suburbs (real coordinates), cuisines with believable menus and their dietary chips,
// people, and the words entries are written in. Pure data; seed.mjs does the drawing.

// [suburb, lat, lng, postcode, weight] — weight = how much food the suburb gets.
export const CITIES = {
  melbourne: {
    state: 'VIC', restaurants: 150, streets: ['Smith St', 'Gertrude St', 'Brunswick St', 'Lygon St', 'Sydney Rd', 'Chapel St', 'Swan St', 'Bridge Rd', 'Barkly St', 'Acland St', 'Glen Huntly Rd', 'High St', 'Johnston St', 'Victoria St', 'Flinders Ln', 'Little Bourke St', 'Degraves St', 'Hardware Ln', 'Hope St', 'Nicholson St'],
    suburbs: [
      ['Melbourne', -37.8136, 144.9631, '3000', 14], ['Fitzroy', -37.7990, 144.9780, '3065', 10], ['Collingwood', -37.8020, 144.9880, '3066', 7],
      ['Carlton', -37.8000, 144.9671, '3053', 6], ['Brunswick', -37.7670, 144.9610, '3056', 7], ['Brunswick East', -37.7717, 144.9720, '3057', 4],
      ['Northcote', -37.7700, 144.9990, '3070', 6], ['Thornbury', -37.7550, 145.0050, '3071', 4], ['Richmond', -37.8230, 144.9980, '3121', 7],
      ['South Yarra', -37.8380, 144.9930, '3141', 4], ['Prahran', -37.8500, 144.9930, '3181', 5], ['Windsor', -37.8560, 144.9920, '3181', 3],
      ['St Kilda', -37.8676, 144.9810, '3182', 4], ['South Melbourne', -37.8330, 144.9580, '3205', 3], ['Footscray', -37.8000, 144.8990, '3011', 5],
      ['Yarraville', -37.8160, 144.8900, '3013', 3], ['Abbotsford', -37.8040, 144.9990, '3067', 3], ['Hawthorn', -37.8220, 145.0350, '3122', 2],
      ['Box Hill', -37.8190, 145.1220, '3128', 3], ['Springvale', -37.9500, 145.1530, '3171', 3], ['Carnegie', -37.8870, 145.0580, '3163', 2],
      ['Elsternwick', -37.8850, 145.0010, '3185', 2], ['Coburg', -37.7430, 144.9660, '3058', 3], ['Preston', -37.7430, 145.0130, '3072', 3],
      ['Glen Waverley', -37.8780, 145.1650, '3150', 2], ['Williamstown', -37.8580, 144.8980, '3016', 2],
    ],
  },
  sydney: {
    state: 'NSW', restaurants: 70, streets: ['Crown St', 'King St', 'Oxford St', 'Enmore Rd', 'Glebe Point Rd', 'Bourke St', 'Campbell Pde', 'George St', 'Sussex St', 'Darlinghurst Rd', 'Regent St', 'Church St', 'The Corso', 'Marrickville Rd'],
    suburbs: [
      ['Sydney', -33.8688, 151.2093, '2000', 10], ['Surry Hills', -33.8850, 151.2110, '2010', 9], ['Darlinghurst', -33.8790, 151.2190, '2010', 5],
      ['Newtown', -33.8970, 151.1790, '2042', 7], ['Marrickville', -33.9110, 151.1550, '2204', 5], ['Bondi', -33.8910, 151.2770, '2026', 4],
      ['Paddington', -33.8840, 151.2310, '2021', 3], ['Chippendale', -33.8870, 151.1990, '2008', 3], ['Redfern', -33.8930, 151.2040, '2016', 3],
      ['Potts Point', -33.8700, 151.2250, '2011', 3], ['Haymarket', -33.8800, 151.2030, '2000', 5], ['Parramatta', -33.8150, 151.0010, '2150', 3],
      ['Manly', -33.7970, 151.2880, '2095', 2], ['Glebe', -33.8790, 151.1850, '2037', 2], ['Cabramatta', -33.8940, 150.9380, '2166', 3],
    ],
  },
  brisbane: {
    state: 'QLD', restaurants: 30, streets: ['James St', 'Brunswick St', 'Boundary St', 'Vulture St', 'Merthyr Rd', 'Given Tce', 'Logan Rd', 'Wandoo St'],
    suburbs: [
      ['Brisbane City', -27.4698, 153.0251, '4000', 6], ['Fortitude Valley', -27.4570, 153.0340, '4006', 6], ['West End', -27.4820, 153.0100, '4101', 5],
      ['South Brisbane', -27.4800, 153.0200, '4101', 4], ['New Farm', -27.4670, 153.0510, '4005', 4], ['Woolloongabba', -27.4880, 153.0360, '4102', 3],
      ['Teneriffe', -27.4560, 153.0470, '4005', 2],
    ],
  },
  adelaide: {
    state: 'SA', restaurants: 25, streets: ['Rundle St', 'Gouger St', 'The Parade', "O'Connell St", 'Jetty Rd', 'Prospect Rd', 'King William Rd', 'Hindley St'],
    suburbs: [
      ['Adelaide', -34.9285, 138.6007, '5000', 8], ['North Adelaide', -34.9060, 138.5930, '5006', 4], ['Norwood', -34.9210, 138.6300, '5067', 4],
      ['Glenelg', -34.9800, 138.5150, '5045', 3], ['Prospect', -34.8840, 138.5940, '5082', 3], ['Unley', -34.9500, 138.6070, '5061', 3],
      ['Hindmarsh', -34.9070, 138.5690, '5007', 2],
    ],
  },
  perth: {
    state: 'WA', restaurants: 25, streets: ['William St', 'James St', 'Beaufort St', 'Oxford St', 'Rokeby Rd', 'South Tce', 'Albany Hwy', 'Market St'],
    suburbs: [
      ['Perth', -31.9505, 115.8605, '6000', 6], ['Northbridge', -31.9470, 115.8570, '6003', 6], ['Fremantle', -32.0569, 115.7439, '6160', 5],
      ['Mount Lawley', -31.9340, 115.8710, '6050', 4], ['Leederville', -31.9360, 115.8410, '6007', 3], ['Subiaco', -31.9490, 115.8270, '6008', 2],
      ['Victoria Park', -31.9760, 115.8990, '6100', 2],
    ],
  },
};

// Cuisine → [menu of [dish, dietary codes]], name patterns (X = a word from NAME_WORDS), city weight.
export const CUISINES = {
  Italian: { w: 12, names: ['Trattoria X', 'X Pasta Bar', 'Osteria X', 'Bar X', 'Cucina X'], menu: [
    ['Cacio e pepe', ['v']], ['Rigatoni alla vodka', ['v']], ['Potato gnocchi', ['v']], ['Tiramisu', ['v']], ['Burrata', ['v', 'gf']],
    ['Lasagne', []], ['Arancini', ['v']], ['Carbonara', []], ['Panna cotta', ['gf']], ['Pappardelle ragu', []], ['Focaccia', ['vg', 'df']], ['Cannoli', ['v']]] },
  Pizza: { w: 6, names: ['X Pizza', 'Pizzeria X', 'X Slice'], menu: [
    ['Margherita', ['v']], ['Pepperoni', []], ['Hot honey soppressata', []], ['Funghi', ['v']], ['Marinara', ['vg', 'df']], ['Garlic knots', ['v']], ['Nduja and stracciatella', []]] },
  Japanese: { w: 8, names: ['X Izakaya', 'Sushi X', 'X Ramen', 'Kappo X'], menu: [
    ['Salmon nigiri', ['df']], ['Tonkotsu ramen', ['df']], ['Chicken karaage', ['df']], ['Agedashi tofu', ['v']], ['Wagyu don', ['df']], ['Pork gyoza', ['df']],
    ['Miso eggplant', ['vg', 'df']], ['Matcha soft serve', ['v']], ['Spicy tuna roll', ['df']], ['Katsu sando', []]] },
  Korean: { w: 5, names: ['X Korean BBQ', 'Seoul X', 'X Pocha'], menu: [
    ['Korean fried chicken', ['df']], ['Bibimbap', ['df']], ['Kimchi pancake', ['v', 'df']], ['Tteokbokki', ['df']], ['Bulgogi', ['df']], ['Japchae', ['df']], ['Galbi', ['df', 'gf']]] },
  Chinese: { w: 8, names: ['X Dumpling House', 'Golden X', 'X Noodle Bar', 'Dragon X'], menu: [
    ['Xiao long bao', ['df']], ['Char siu bao', ['df']], ['Har gow', ['df']], ['Siu mai', ['df']], ['Dan dan noodles', ['df']], ['Mapo tofu', ['df']],
    ['Peking duck pancakes', ['df']], ['Salt and pepper squid', ['df']], ['Egg tarts', ['v']], ['Gai lan', ['vg', 'gf', 'df']]] },
  Vietnamese: { w: 7, names: ['Pho X', 'X Banh Mi', 'Little X'], menu: [
    ['Pho bo', ['gf', 'df']], ['Banh mi', ['df']], ['Rice paper rolls', ['gf', 'df']], ['Bun cha', ['df']], ['Broken rice', ['df']], ['Crispy pork belly', ['gf', 'df']], ['Lemongrass tofu', ['vg', 'gf', 'df']]] },
  Thai: { w: 7, names: ['X Thai', 'Baan X', 'X Kitchen'], menu: [
    ['Pad see ew', ['df']], ['Green curry', ['gf', 'df']], ['Som tum', ['gf', 'df']], ['Massaman beef', ['gf', 'df']], ['Crying tiger', ['gf', 'df']], ['Pad thai', ['df']],
    ['Mango sticky rice', ['vg', 'gf']], ['Boat noodles', ['df']]] },
  Indian: { w: 6, names: ['X Tandoor', 'Spice X', 'X Dosa House'], menu: [
    ['Butter chicken', ['gf']], ['Lamb rogan josh', ['gf']], ['Dal makhani', ['v', 'gf']], ['Garlic naan', ['v']], ['Masala dosa', ['vg', 'gf']], ['Chana masala', ['vg', 'gf', 'df']],
    ['Samosa chaat', ['v']], ['Paneer tikka', ['v', 'gf']]] },
  'Sri Lankan': { w: 2, names: ['X Hoppers', 'Lanka X'], menu: [
    ['Egg hoppers', ['v', 'gf']], ['Kottu roti', []], ['Fish curry', ['gf', 'df']], ['Pol sambol', ['vg', 'gf', 'df']], ['Lamprais', ['df']]] },
  Greek: { w: 4, names: ['X Taverna', 'Kafeneio X'], menu: [
    ['Lamb souvlaki', []], ['Saganaki', ['v', 'gf']], ['Spanakopita', ['v']], ['Loukoumades', ['v']], ['Grilled octopus', ['gf', 'df']], ['Dips plate', ['v']], ['Moussaka', []]] },
  Lebanese: { w: 4, names: ['X Grill', 'Beit X', 'X Charcoal'], menu: [
    ['Falafel', ['vg', 'gf', 'df']], ['Hummus', ['vg', 'gf', 'df']], ['Lamb shawarma', ['df']], ['Fattoush', ['vg', 'df']], ['Baba ghanoush', ['vg', 'gf', 'df']], ['Chicken shish', ['gf', 'df']], ['Knafeh', ['v']]] },
  Mexican: { w: 5, names: ['X Cantina', 'Taqueria X', 'X Tacos'], menu: [
    ['Fish tacos', ['df']], ['Al pastor tacos', ['gf', 'df']], ['Birria', ['gf']], ['Elote', ['v', 'gf']], ['Guacamole', ['vg', 'gf', 'df']], ['Churros', ['v']], ['Quesadilla', ['v']]] },
  Cafe: { w: 10, names: ['X Cafe', 'X Espresso', 'Little X', 'X & Co'], menu: [
    ['Smashed avo', ['v', 'df']], ['Eggs benedict', []], ['Big breakfast', []], ['Ricotta hotcakes', ['v']], ['Chilli scrambled eggs', ['v']], ['Breakfast burrito', []],
    ['Banana bread', ['v']], ['Acai bowl', ['vg', 'gf', 'df']], ['Fried chicken sandwich', []]] },
  Bakery: { w: 4, names: ['X Bakehouse', 'X Patisserie', 'Boulangerie X'], menu: [
    ['Croissant', ['v']], ['Almond croissant', ['v']], ['Pain au chocolat', ['v']], ['Kouign-amann', ['v']], ['Cruffin', ['v']], ['Sausage roll', []], ['Cinnamon scroll', ['v']]] },
  Burgers: { w: 5, names: ['X Burgers', 'X Burger Bar', 'Smash X'], menu: [
    ['Cheeseburger', []], ['Double smash', []], ['Fried chicken burger', []], ['Fries', ['vg', 'df']], ['Onion rings', ['v']], ['Vegan burger', ['vg', 'df']], ['Thickshake', ['v', 'gf']]] },
  'Modern Australian': { w: 7, names: ['X Dining', 'X Wine Room', 'Bistro X', 'X House'], menu: [
    ['Kingfish crudo', ['gf', 'df']], ['Lamb shoulder', ['gf']], ['Roast chicken', ['gf']], ['Beef tartare', ['df']], ['Burnt butter gnocchi', ['v']], ['Pavlova', ['v', 'gf']],
    ['Market fish', ['gf']], ['Duck liver parfait', []]] },
  French: { w: 3, names: ['Bistro X', 'Chez X', 'Le Petit X'], menu: [
    ['Steak frites', ['gf']], ['Duck confit', ['gf']], ['French onion soup', []], ['Creme brulee', ['v', 'gf']], ['Escargot', ['gf']], ['Croque monsieur', []], ['Tarte tatin', ['v']]] },
  Spanish: { w: 3, names: ['Bar X', 'X Tapas', 'Casa X'], menu: [
    ['Patatas bravas', ['vg', 'gf', 'df']], ['Jamon croquetas', []], ['Gambas al ajillo', ['gf', 'df']], ['Jamon plate', ['gf', 'df']], ['Seafood paella', ['gf', 'df']], ['Basque cheesecake', ['v', 'gf']]] },
  Seafood: { w: 3, names: ['X Fish Co', 'X Oyster Bar', 'The X Shack'], menu: [
    ['Fish and chips', ['df']], ['Oysters', ['gf', 'df']], ['Lobster roll', []], ['Chilli crab', ['df']], ['Salt and pepper calamari', ['df']], ['Prawn cocktail', ['gf']]] },
  Malaysian: { w: 4, names: ['X Malaysian', 'Kopi X', 'X Hawker'], menu: [
    ['Nasi lemak', ['df']], ['Char kway teow', ['df']], ['Curry laksa', ['df']], ['Roti canai', ['v']], ['Beef rendang', ['gf', 'df']], ['Hainanese chicken rice', ['df']]] },
  Ethiopian: { w: 1, names: ['X Ethiopian', 'Addis X'], menu: [
    ['Doro wat', ['gf', 'df']], ['Veggie injera platter', ['vg', 'df']], ['Beef tibs', ['df']], ['Misir wat', ['vg', 'gf', 'df']]] },
  'Wine bar': { w: 5, names: ['X Wine Bar', 'Bar X', 'X Enoteca'], menu: [
    ['Anchovy toast', ['df']], ['Burrata', ['v', 'gf']], ['Charcuterie plate', ['gf', 'df']], ['Fried olives', ['v']], ['Steak tartare', ['df']], ['Cheese plate', ['v']], ['Potato gratin', ['v', 'gf']]] },
};

export const NAME_WORDS = [
  'Luna', 'Nonna', 'Sorella', 'Fratelli', 'Marlo', 'Oyster', 'Juniper', 'Lotus', 'Saffron', 'Kumo', 'Hana', 'Momo', 'Bao', 'Ember', 'Cinder', 'Olive',
  'Harbour', 'Laneway', 'Paloma', 'Pepper', 'Maple', 'Fig', 'Sesame', 'Tamarind', 'Clove', 'Basil', 'Coco', 'Otto', 'Rosa', 'Vela', 'Nomi', 'Kiko',
  'Gold', 'Jade', 'Red Lantern', 'Blue Door', 'Corner', 'Wattle', 'Banksia', 'Salt', 'Smoke', 'Copper', 'Arbor', 'Linden', 'Honey', 'Neon', 'Velvet',
  'Mimi', 'Sunny', 'Lucky', 'Tiger', 'Crane', 'Fox', 'Magpie', 'Wren', 'Heron', 'Pelican', 'Moth', 'Oak', 'Birch',
];

// 60 handles: varied, some long (≤ 30, [a-z0-9_] — the client's rule), a few very short.
export const HANDLES = [
  'noodlenerd', 'brunchbureau', 'the_dumpling_diaries', 'flatwhiteforever', 'saltandvinegar', 'laksa_lover_melb', 'crumbtrail', 'midweekmunchies',
  'spoonfed', 'okonomi_yaki_yes', 'currycartographer', 'pastapilgrim', 'tacotuesdayeveryday', 'the_hungry_accountant_melb', 'bakerybeforebreakfast',
  'sydneysizzle', 'bondibites', 'newtownnosh', 'harbourhunger', 'parramattaplates', 'brisbanebrunch', 'valleyvittles', 'adelaideappetite',
  'glenelggrazer', 'perthplates', 'freofeeds', 'jen_eats_everything', 'marcus_k', 'dan_the_dim_sum_man', 'soph', 'liv_n_eat', 'raj_rates_it',
  'hannah_b', 'the_late_lunch_club', 'eatwithemma', 'chilli_oil_on_everything', 'wontonwanderer', 'pho_real', 'gnocchi_or_nothing', 'brothandbread',
  'sourdough_and_sunday_papers', 'weekendwaffle', 'kimchi_kween', 'smashburgersociety', 'second_helping', 'tablefortwo_again', 'northside_nibbles',
  'southside_supper', 'cbd_desk_lunch_report', 'matcha_maddie', 'the_offal_truth', 'veggie_vic', 'plantbased_paul', 'glutenfree_gabby',
  'dessertfirst_always', 'spice_route_sam', 'ramen_rankings_official', 'jo', 'mk', 'oyster_o_clock',
];

// Home city per handle index when the handle says so; others are drawn.
export const HOME_HINTS = {
  sydneysizzle: 'sydney', bondibites: 'sydney', newtownnosh: 'sydney', harbourhunger: 'sydney', parramattaplates: 'sydney',
  brisbanebrunch: 'brisbane', valleyvittles: 'brisbane', adelaideappetite: 'adelaide', glenelggrazer: 'adelaide',
  perthplates: 'perth', freofeeds: 'perth', laksa_lover_melb: 'melbourne', the_hungry_accountant_melb: 'melbourne',
  northside_nibbles: 'melbourne', southside_supper: 'melbourne', cbd_desk_lunch_report: 'melbourne', veggie_vic: 'melbourne',
};

// What a handle eats most, when it says so.
export const TASTE_HINTS = {
  noodlenerd: ['Japanese', 'Chinese', 'Vietnamese', 'Malaysian'], the_dumpling_diaries: ['Chinese'], laksa_lover_melb: ['Malaysian'],
  okonomi_yaki_yes: ['Japanese'], currycartographer: ['Indian', 'Sri Lankan', 'Thai'], pastapilgrim: ['Italian'], tacotuesdayeveryday: ['Mexican'],
  bakerybeforebreakfast: ['Bakery', 'Cafe'], dan_the_dim_sum_man: ['Chinese'], chilli_oil_on_everything: ['Chinese', 'Korean', 'Thai'],
  wontonwanderer: ['Chinese'], pho_real: ['Vietnamese'], gnocchi_or_nothing: ['Italian'], kimchi_kween: ['Korean'], smashburgersociety: ['Burgers'],
  matcha_maddie: ['Japanese', 'Cafe'], veggie_vic: ['Indian', 'Lebanese', 'Vietnamese'], plantbased_paul: ['Lebanese', 'Indian', 'Ethiopian'],
  dessertfirst_always: ['Bakery', 'Cafe'], spice_route_sam: ['Indian', 'Sri Lankan', 'Ethiopian', 'Malaysian'], ramen_rankings_official: ['Japanese'],
  oyster_o_clock: ['Seafood', 'Wine bar'], brunchbureau: ['Cafe'], brisbanebrunch: ['Cafe'], weekendwaffle: ['Cafe', 'Bakery'],
  sourdough_and_sunday_papers: ['Bakery', 'Cafe'], brothandbread: ['Vietnamese', 'Japanese', 'Bakery'], glutenfree_gabby: ['Vietnamese', 'Thai', 'Lebanese'],
};

export const FIRST = ['Jen', 'Marcus', 'Dan', 'Sophie', 'Olivia', 'Raj', 'Hannah', 'Emma', 'Liam', 'Noah', 'Mia', 'Chloe', 'Ava', 'Zara', 'Kenji', 'Mei',
  'Tariq', 'Nadia', 'Priyanka', 'Luca', 'Giulia', 'Sam', 'Ella', 'Jack', 'Ruby', 'Oscar', 'Isla', 'Hugo', 'Leila', 'Tom', 'Anh', 'Minh', 'Sienna',
  'Paul', 'Gabby', 'Maddie', 'Kwame', 'Aroha', 'Yusuf', 'Ines'];
export const LAST = ['Nguyen', 'Smith', 'Chen', 'Kaur', 'Rossi', 'Papadopoulos', 'Kim', 'Tanaka', 'Haddad', 'OBrien', 'Walker', 'Patel', 'Lee',
  'Williams', 'Tran', 'Singh', 'Costa', 'Mensah', 'Ngata', 'Fernando'];

export const BIOS = ['Eats first, photos later.', 'Rating everything so you do not have to.', 'Here for the second helping.',
  'Dumplings are a personality.', 'Brunch is a food group.', 'Will cross town for good bread.', 'Trying every laksa in the city.',
  'Weeknight cook, weekend eater.', 'Mostly noodles.', 'The dessert menu is the menu.', null, null, null];

export const WHO = ['Sam', 'the team', 'my sister', 'Mum and Dad', 'the book club', 'a mate from uni', 'my partner', 'the crew', 'work people', 'Jess'];
export const OPENERS_PLACE = ['{P} with {W}.', 'Dinner at {P}.', 'Lunch at {P}, {V}.', '{P} again.', 'Finally tried {P}.', '{P} for {O}.',
  'Back at {P}.', 'Walked past {P} and got a table.', '{P}, {V}.'];
export const OPENERS_BARE = ['Dinner with {W}.', 'Quick lunch.', 'Late one.', 'Birthday dinner.', 'Solo lunch at the bar.', 'Takeaway night.', ''];
export const VIBES = ['packed as usual', 'quiet for a Tuesday', 'loud but fun', 'sat outside', 'short queue', 'good playlist', 'great service'];
export const OCCASIONS = ['a birthday', 'date night', 'a work lunch', 'a farewell', 'Friday drinks', 'a Sunday feed'];

export const NOTES_HIGH = ['would order again', 'perfectly cooked', 'the best thing on the table', 'generous serve', 'crispy edges',
  'really well balanced', 'worth the queue', 'ordered a second', 'still thinking about it'];
export const NOTES_MID = ['fine but forgettable', 'a touch too salty', 'solid', 'bit small for the price', 'good not great', 'needed more sauce'];
export const NOTES_LOW = ['overcooked', 'pretty bland', 'skip it', 'arrived lukewarm', 'far too sweet', 'soggy'];
export const NOTES_NONE = ['lovely', 'really good', 'a bit much', 'nice enough', 'the surprise of the night', 'shared it, gone in a minute'];
export const TAG_WORDS = { gf: 'GF', df: 'DF', v: 'veg', vg: 'vegan', nf: 'nut free' };
