/* Indian kitchen ingredient directory.
   Format: Name | Category | Unit set | aliases (Hindi / regional / alternate spellings)
   The unit set decides which units a user may pick. The first unit in the set is the default.
   Becomes the ingredient_catalog table (name, category, default_unit, allowed_units, aliases). */
window.UNIT_SETS = {
  CNT:   ['pcs', 'g', 'kg'],          // countable produce: onion, tomato, potato
  CNTG:  ['g', 'kg', 'pcs'],          // sold by weight, sometimes counted: ginger, beans
  PCS:   ['pcs'],                      // only counted: lemon, coconut
  LEAF:  ['bunch', 'g'],              // leafy greens and herbs
  WT:    ['g', 'kg'],                 // dals, rice, flours, meat
  LIQ:   ['ml', 'L'],                 // milk, oil
  FAT:   ['ml', 'L', 'g', 'kg'],      // ghee: jars by weight or volume
  SPICE: ['g', 'tsp', 'tbsp'],        // ground and whole spices
  PINCH: ['g', 'pinch'],              // hing, saffron
  EGG:   ['pcs', 'dozen'],
  SLICE: ['slices', 'packet'],        // bread
  PACK:  ['packet', 'g'],             // noodles, ready mixes
  PASTE: ['g', 'tbsp'],               // ginger-garlic paste, pickles
  SAUCE: ['ml', 'g', 'tbsp'],         // ketchup, soy sauce
  DAIRY: ['g', 'kg'],                 // curd, paneer, butter, cheese
  CREAM: ['ml', 'g'],
  STICK: ['pcs', 'g'],                // cinnamon, bay leaf, dry red chilli
  CUP:   ['g', 'kg', 'tbsp']          // sugar, jaggery, sooji in small amounts
};

window.INGREDIENTS_RAW = `
Onion|Vegetables|CNT|pyaz,pyaaz,kanda,dungri
Red onion|Vegetables|CNT|lal pyaz
Spring onion|Vegetables|LEAF|hara pyaz,scallion
Shallots|Vegetables|CNTG|sambar onion,chhota pyaz
Tomato|Vegetables|CNT|tamatar,tameta
Cherry tomato|Vegetables|CNTG|
Potato|Vegetables|CNT|aloo,batata
Sweet potato|Vegetables|CNT|shakarkandi
Garlic|Vegetables|CNTG|lahsun,lehsun,lasun
Ginger|Vegetables|CNTG|adrak,adu
Green chilli|Vegetables|CNTG|hari mirch,mirchi
Capsicum|Vegetables|CNT|shimla mirch,bell pepper
Red bell pepper|Vegetables|CNT|lal shimla mirch
Yellow bell pepper|Vegetables|CNT|
Carrot|Vegetables|CNT|gajar
Beetroot|Vegetables|CNT|chukandar
Radish|Vegetables|CNT|mooli,muli
Cauliflower|Vegetables|CNT|gobhi,phool gobhi,gobi
Cabbage|Vegetables|CNT|patta gobhi,band gobhi
Broccoli|Vegetables|CNT|
Green peas|Vegetables|WT|matar,mutter,peas
Frozen peas|Vegetables|WT|frozen matar
French beans|Vegetables|CNTG|beans,phali
Cluster beans|Vegetables|WT|gawar,guar phali
Broad beans|Vegetables|WT|sem,papdi
Okra|Vegetables|WT|bhindi,lady finger,ladies finger
Brinjal|Vegetables|CNT|baingan,eggplant,aubergine,vangi
Bottle gourd|Vegetables|CNT|lauki,dudhi,ghiya
Ridge gourd|Vegetables|CNT|turai,tori,dodka
Bitter gourd|Vegetables|CNT|karela
Snake gourd|Vegetables|CNT|chichinda,padwal
Ash gourd|Vegetables|CNTG|petha
Pumpkin|Vegetables|CNTG|kaddu,sitaphal,lal kaddu
Tinda|Vegetables|CNT|round gourd
Parwal|Vegetables|CNT|pointed gourd
Cucumber|Vegetables|CNT|kheera,kakdi
Zucchini|Vegetables|CNT|
Raw banana|Vegetables|CNT|kaccha kela,plantain
Raw papaya|Vegetables|CNTG|kaccha papita
Drumstick|Vegetables|CNT|sahjan,moringa,shevga
Mushroom|Vegetables|WT|khumb,kukurmutta
Baby corn|Vegetables|WT|
Sweet corn|Vegetables|WT|makai,bhutta,corn
Jackfruit|Vegetables|WT|kathal
Colocasia|Vegetables|WT|arbi,arvi,taro
Yam|Vegetables|WT|suran,jimikand,elephant foot yam
Lotus stem|Vegetables|WT|kamal kakdi,nadru
Raw mango|Vegetables|CNT|kairi,kaccha aam
Lemon|Vegetables|PCS|nimbu,limbu,lime
Spinach|Leafy greens & herbs|LEAF|palak
Fenugreek leaves|Leafy greens & herbs|LEAF|methi,methi leaves
Coriander leaves|Leafy greens & herbs|LEAF|dhaniya,dhania,hara dhaniya,cilantro,coriander
Mint|Leafy greens & herbs|LEAF|pudina
Curry leaves|Leafy greens & herbs|LEAF|kadi patta,kadhi patta,meetha neem
Mustard greens|Leafy greens & herbs|LEAF|sarson,sarson ka saag
Dill leaves|Leafy greens & herbs|LEAF|suva,shepu,soya leaves
Amaranth leaves|Leafy greens & herbs|LEAF|chaulai,lal saag
Bathua|Leafy greens & herbs|LEAF|chenopodium
Lettuce|Leafy greens & herbs|LEAF|
Basil|Leafy greens & herbs|LEAF|tulsi
Banana|Fruits|CNT|kela
Apple|Fruits|CNT|seb
Mango|Fruits|CNT|aam
Orange|Fruits|CNT|santra,narangi
Papaya|Fruits|CNTG|papita
Pomegranate|Fruits|CNT|anar
Grapes|Fruits|WT|angoor
Guava|Fruits|CNT|amrud
Pineapple|Fruits|CNT|ananas
Watermelon|Fruits|CNTG|tarbooz
Muskmelon|Fruits|CNT|kharbooja
Chikoo|Fruits|CNT|sapota
Pear|Fruits|CNT|nashpati
Strawberry|Fruits|WT|
Coconut|Fruits|PCS|nariyal,thengai
Fresh grated coconut|Fruits|WT|kasa hua nariyal
Avocado|Fruits|CNT|
Toor dal|Dals & pulses|WT|arhar dal,tuvar dal,pigeon pea,tur dal
Moong dal|Dals & pulses|WT|yellow moong,mung dal
Green moong|Dals & pulses|WT|sabut moong,whole moong
Masoor dal|Dals & pulses|WT|red lentil,lal masoor
Whole masoor|Dals & pulses|WT|sabut masoor,brown lentil
Chana dal|Dals & pulses|WT|split bengal gram
Urad dal|Dals & pulses|WT|white urad,dhuli urad
Whole urad|Dals & pulses|WT|sabut urad,kali dal,black gram
Rajma|Dals & pulses|WT|kidney beans
Kabuli chana|Dals & pulses|WT|chickpeas,chole,safed chana,garbanzo
Kala chana|Dals & pulses|WT|black chickpeas,bengal gram
Lobia|Dals & pulses|WT|black eyed beans,chawli
Moth beans|Dals & pulses|WT|matki,moth dal
Horse gram|Dals & pulses|WT|kulthi,kollu
Soya chunks|Dals & pulses|WT|nutrela,soya badi
Roasted chana|Dals & pulses|WT|bhuna chana,dalia chana
Basmati rice|Rice & grains|WT|basmati chawal
Rice|Rice & grains|WT|chawal,sona masoori,kolam,white rice
Brown rice|Rice & grains|WT|
Idli rice|Rice & grains|WT|parboiled rice,ukda chawal
Poha|Rice & grains|WT|flattened rice,chivda,aval,pohe
Puffed rice|Rice & grains|WT|murmura,kurmura,mamra
Sooji|Rice & grains|CUP|rava,semolina,suji
Dalia|Rice & grains|WT|broken wheat,lapsi,daliya
Oats|Rice & grains|WT|
Vermicelli|Rice & grains|PACK|seviyan,semiya,sevai
Sabudana|Rice & grains|WT|sago,tapioca pearls
Quinoa|Rice & grains|WT|
Millet|Rice & grains|WT|bajra,jowar,ragi grain
Atta|Flours|WT|wheat flour,gehun ka atta,chapati flour
Multigrain atta|Flours|WT|
Maida|Flours|WT|all purpose flour,refined flour
Besan|Flours|WT|gram flour,chickpea flour
Rice flour|Flours|WT|chawal ka atta
Ragi flour|Flours|WT|nachni,finger millet flour
Jowar flour|Flours|WT|jowar atta,sorghum flour
Bajra flour|Flours|WT|bajra atta,pearl millet flour
Makki ka atta|Flours|WT|corn flour,maize flour
Cornflour|Flours|CUP|corn starch,arrowroot
Idli batter|Flours|WT|dosa batter
Milk|Dairy|LIQ|doodh,dudh
Curd|Dairy|DAIRY|dahi,yogurt,yoghurt
Paneer|Dairy|DAIRY|cottage cheese
Butter|Dairy|DAIRY|makhan,makkhan
Cheese|Dairy|DAIRY|cheese slice,mozzarella
Fresh cream|Dairy|CREAM|malai,cream
Buttermilk|Dairy|LIQ|chaas,chhach,mattha
Khoya|Dairy|DAIRY|mawa
Condensed milk|Dairy|CREAM|milkmaid
Eggs|Eggs|EGG|anda,ande,egg
Chicken|Meat & seafood|WT|murgi,murgh
Mutton|Meat & seafood|WT|goat meat,gosht
Fish|Meat & seafood|WT|machli,macchi
Prawns|Meat & seafood|WT|jhinga,shrimp
Keema|Meat & seafood|WT|mince,minced meat
Jeera|Whole spices|SPICE|cumin,cumin seeds,zeera
Mustard seeds|Whole spices|SPICE|rai,sarson ke beej,rye
Fennel seeds|Whole spices|SPICE|saunf,variyali
Fenugreek seeds|Whole spices|SPICE|methi dana,methi seeds
Ajwain|Whole spices|SPICE|carom seeds,owa
Kalonji|Whole spices|SPICE|nigella seeds,onion seeds
Coriander seeds|Whole spices|SPICE|sabut dhaniya
Black pepper|Whole spices|SPICE|kali mirch,peppercorn
Cloves|Whole spices|STICK|laung,lavang
Green cardamom|Whole spices|STICK|elaichi,choti elaichi
Black cardamom|Whole spices|STICK|badi elaichi
Cinnamon|Whole spices|STICK|dalchini
Bay leaf|Whole spices|STICK|tej patta
Dry red chilli|Whole spices|STICK|sukhi lal mirch,sabut lal mirch
Star anise|Whole spices|STICK|chakri phool,badiyan
Mace|Whole spices|SPICE|javitri
Nutmeg|Whole spices|STICK|jaiphal
Poppy seeds|Whole spices|SPICE|khus khus,posto
Haldi|Ground masalas|SPICE|turmeric,haldi powder,halad
Red chilli powder|Ground masalas|SPICE|lal mirch powder,mirchi powder,chilli powder
Kashmiri chilli powder|Ground masalas|SPICE|degi mirch
Coriander powder|Ground masalas|SPICE|dhaniya powder
Cumin powder|Ground masalas|SPICE|jeera powder,bhuna jeera
Garam masala|Ground masalas|SPICE|
Chaat masala|Ground masalas|SPICE|
Kitchen king masala|Ground masalas|SPICE|
Pav bhaji masala|Ground masalas|SPICE|
Sambar powder|Ground masalas|SPICE|sambhar masala
Rasam powder|Ground masalas|SPICE|
Chole masala|Ground masalas|SPICE|chana masala powder
Biryani masala|Ground masalas|SPICE|
Amchur|Ground masalas|SPICE|dry mango powder,amchoor
Kasuri methi|Ground masalas|SPICE|dried fenugreek leaves
Black salt|Ground masalas|SPICE|kala namak
Hing|Ground masalas|PINCH|asafoetida,heeng
Saffron|Ground masalas|PINCH|kesar
Salt|Ground masalas|CUP|namak,table salt
Sugar|Sweeteners|CUP|cheeni,shakkar
Jaggery|Sweeteners|CUP|gur,gud,vellam
Honey|Sweeteners|SAUCE|shahad,madh
Brown sugar|Sweeteners|CUP|
Mustard oil|Oils & ghee|LIQ|sarson ka tel,kachi ghani
Sunflower oil|Oils & ghee|LIQ|refined oil,oil,cooking oil
Groundnut oil|Oils & ghee|LIQ|peanut oil,moongphali tel
Coconut oil|Oils & ghee|LIQ|nariyal tel
Olive oil|Oils & ghee|LIQ|
Sesame oil|Oils & ghee|LIQ|til ka tel,gingelly oil
Ghee|Oils & ghee|FAT|desi ghee,clarified butter
Peanuts|Nuts & seeds|WT|moongphali,shengdana,groundnut
Cashews|Nuts & seeds|WT|kaju
Almonds|Nuts & seeds|WT|badam
Raisins|Nuts & seeds|WT|kishmish,kismis
Walnuts|Nuts & seeds|WT|akhrot
Pistachios|Nuts & seeds|WT|pista
Dates|Nuts & seeds|WT|khajur
Dry coconut|Nuts & seeds|CNTG|copra,sukha nariyal,desiccated coconut
Sesame seeds|Nuts & seeds|SPICE|til
Flax seeds|Nuts & seeds|SPICE|alsi
Makhana|Nuts & seeds|WT|fox nuts,lotus seeds
Tamarind|Sauces & pastes|PASTE|imli,chinch
Ginger garlic paste|Sauces & pastes|PASTE|adrak lahsun paste
Tomato puree|Sauces & pastes|SAUCE|
Tomato ketchup|Sauces & pastes|SAUCE|ketchup,tomato sauce
Soy sauce|Sauces & pastes|SAUCE|
Green chilli sauce|Sauces & pastes|SAUCE|
Red chilli sauce|Sauces & pastes|SAUCE|schezwan sauce
Vinegar|Sauces & pastes|SAUCE|sirka
Mayonnaise|Sauces & pastes|SAUCE|mayo
Peanut butter|Sauces & pastes|PASTE|
Coconut milk|Sauces & pastes|SAUCE|nariyal doodh
Mango pickle|Pickles & chutneys|PASTE|aam ka achar,achaar
Lemon pickle|Pickles & chutneys|PASTE|nimbu ka achar
Mixed pickle|Pickles & chutneys|PASTE|achar
Green chutney|Pickles & chutneys|PASTE|hari chutney,pudina chutney
Tamarind chutney|Pickles & chutneys|PASTE|imli chutney,meethi chutney
Papad|Pickles & chutneys|PACK|papadum,appalam
Bread|Breads & ready-to-eat|SLICE|white bread,double roti
Brown bread|Breads & ready-to-eat|SLICE|whole wheat bread
Pav|Breads & ready-to-eat|SLICE|ladi pav,bun
Burger bun|Breads & ready-to-eat|SLICE|
Roti|Breads & ready-to-eat|PCS|chapati,phulka
Frozen paratha|Breads & ready-to-eat|PACK|ready paratha
Tortilla|Breads & ready-to-eat|PCS|wrap
Rusk|Breads & ready-to-eat|PACK|toast,khari
Instant noodles|Packaged & instant|PACK|maggi,noodles
Hakka noodles|Packaged & instant|PACK|
Pasta|Packaged & instant|PACK|macaroni,penne
Cornflakes|Packaged & instant|WT|cereal,muesli
Bhujia|Packaged & instant|WT|namkeen,sev
Tofu|Packaged & instant|DAIRY|
Tea|Beverages|WT|chai patti,tea leaves
Coffee|Beverages|WT|instant coffee
Water|Basics|LIQ|paani,pani
`;

window.INGREDIENTS = window.INGREDIENTS_RAW.trim().split('\n').map(function (line, i) {
  var p = line.split('|');
  var units = window.UNIT_SETS[p[2]];
  return {
    id: i + 1,
    name: p[0],
    category: p[1],
    default_unit: units[0],
    allowed_units: units,
    aliases: (p[3] || '').split(',').map(function (a) { return a.trim(); }).filter(Boolean)
  };
});
