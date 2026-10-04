# Exercise catalog

The catalog includes 145 exercises: the original 10 entries plus 135 additions from [Simply Fitness’s exercise guides](https://www.simplyfitness.com/pages/workout-exercise-guides), reviewed October 3, 2026. All 143 listed guides are represented by an existing exercise or a new entry. Only exercise names and category labels are included; illustrations and execution text are not bundled.

The original 10 names, categories, UUIDs, and positions are retained so starter templates and saved exercise references stay compatible. New entries use the source category. The catalog is bundled with the app and loaded on every launch, including when a saved workout file already exists. Templates and sessions retain their saved exercise snapshots.

Existing-name mappings: Barbell Bench Press → Bench Press; Barbell Deadlift → Deadlift; Standing Barbell Shoulder Press → Overhead Press; Triceps Pressdown → Triceps Pushdown. Squat, Leg Press, Barbell Row, and Pull Up already match. Alternating Dumbbell Curl is a specific variant of the existing generic Dumbbell Curl, so both remain available. Romanian Deadlift remains as an original exercise.

IDs in `LiftLog/Core/ExerciseCatalog.swift` are permanent. Add future entries with unused IDs rather than generating IDs from array positions or changing existing assignments.

| Guide | Source category | Catalog name |
| --- | --- | --- |
| [Barbell Bench Press](https://www.simplyfitness.com/pages/barbell-bench-press) | Chest | Bench Press |
| [Incline Dumbbell Bench Press](https://www.simplyfitness.com/pages/incline-dumbbell-bench-press) | Chest | Incline Dumbbell Bench Press |
| [Pec Deck](https://www.simplyfitness.com/pages/peck-deck) | Chest | Pec Deck |
| [Cable Crossover](https://www.simplyfitness.com/pages/cable-crossover) | Chest | Cable Crossover |
| [Incline Barbell Bench Press](https://www.simplyfitness.com/pages/incline-barbell-bench-press) | Chest | Incline Barbell Bench Press |
| [Dumbbell Bench Press](https://www.simplyfitness.com/pages/dumbbell-bench-press) | Chest | Dumbbell Bench Press |
| [Dumbbell Fly](https://www.simplyfitness.com/pages/dumbbell-fly) | Chest | Dumbbell Fly |
| [Incline Dumbbell Fly](https://www.simplyfitness.com/pages/incline-dumbbell-fly) | Chest | Incline Dumbbell Fly |
| [Chest Press Machine](https://www.simplyfitness.com/pages/chest-press-machine) | Chest | Chest Press Machine |
| [Barbell Declined Bench Press](https://www.simplyfitness.com/pages/barbell-declined-bench-press) | Chest | Barbell Declined Bench Press |
| [Dumbbell Declined Bench Press](https://www.simplyfitness.com/pages/dumbbell-declined-bench-press) | Chest | Dumbbell Declined Bench Press |
| [Push Ups](https://www.simplyfitness.com/pages/push-ups) | Chest | Push Ups |
| [Dumbbell Bent-Over Row (Single Arm)](https://www.simplyfitness.com/pages/dumbbell-bent-over-row-single-arm) | Back | Dumbbell Bent-Over Row (Single Arm) |
| [Wide-Grip Pulldown](https://www.simplyfitness.com/pages/wide-grip-pulldown) | Back | Wide-Grip Pulldown |
| [Seated Cable Row](https://www.simplyfitness.com/pages/seated-cable-row) | Back | Seated Cable Row |
| [Close-Grip Pulldown](https://www.simplyfitness.com/pages/close-grip-pulldown) | Back | Close-Grip Pulldown |
| [Barbell Row](https://www.simplyfitness.com/pages/barbell-row) | Back | Barbell Row |
| [Behind-Neck Pulldown](https://www.simplyfitness.com/pages/behind-neck-pulldown) | Back | Behind-Neck Pulldown |
| [Reverse-Grip Pulldown](https://www.simplyfitness.com/pages/reverse-grip-pulldown) | Back | Reverse-Grip Pulldown |
| [Rope Pulldown](https://www.simplyfitness.com/pages/rope-pulldown) | Back | Rope Pulldown |
| [T-Bar Rows](https://www.simplyfitness.com/pages/t-bar-rows) | Back | T-Bar Rows |
| [Barbell Bent Over Rows Supinated Grip](https://www.simplyfitness.com/pages/barbell-bent-over-rows-supinated-grip) | Back | Barbell Bent Over Rows Supinated Grip |
| [Pull Up](https://www.simplyfitness.com/pages/pull-up) | Back | Pull Up |
| [Behind the Neck Pull Up](https://www.simplyfitness.com/pages/behind-the-neck-pull-up) | Back | Behind the Neck Pull Up |
| [Pull Up with a Supinated Grip](https://www.simplyfitness.com/pages/pull-up-with-a-supinated-grip) | Back | Pull Up with a Supinated Grip |
| [Straight Arm Lat Pulldown](https://www.simplyfitness.com/pages/straight-arm-lat-pulldown) | Back | Straight Arm Lat Pulldown |
| [Dumbbell Bent Over Rows](https://www.simplyfitness.com/pages/dumbbell-bent-over-rows) | Back | Dumbbell Bent Over Rows |
| [Dumbbell Pullover](https://www.simplyfitness.com/pages/dumbbell-pullover) | Back | Dumbbell Pullover |
| [Barbell Pullover](https://www.simplyfitness.com/pages/barbell-pullover) | Back | Barbell Pullover |
| [Barbell Deadlift](https://www.simplyfitness.com/pages/barbell-deadlift) | Back | Deadlift |
| [Barbell Sumo Deadlift](https://www.simplyfitness.com/pages/barbell-sumo-deadlift) | Back | Barbell Sumo Deadlift |
| [Trap Bar Deadlift](https://www.simplyfitness.com/pages/trap-bar-deadlift) | Back | Trap Bar Deadlift |
| [Dumbbell Deadlift](https://www.simplyfitness.com/pages/dumbbell-deadlift) | Back | Dumbbell Deadlift |
| [Barbell Shrug](https://www.simplyfitness.com/pages/barbell-shrug) | Back | Barbell Shrug |
| [Dumbbell Shrugs](https://www.simplyfitness.com/pages/dumbbell-shrugs) | Back | Dumbbell Shrugs |
| [Dumbbell Shoulder Press](https://www.simplyfitness.com/pages/dumbbell-shoulder-press) | Shoulders | Dumbbell Shoulder Press |
| [Dumbbell Lateral Raise](https://www.simplyfitness.com/pages/dumbbell-lateral-raise) | Shoulders | Dumbbell Lateral Raise |
| [Dumbbell Front Raise](https://www.simplyfitness.com/pages/dumbbell-front-raise) | Shoulders | Dumbbell Front Raise |
| [High Cable Rear Delt Fly](https://www.simplyfitness.com/pages/high-cable-rear-delt-fly) | Shoulders | High Cable Rear Delt Fly |
| [Smith Machine Shoulder Press](https://www.simplyfitness.com/pages/smith-machine-shoulder-press) | Shoulders | Smith Machine Shoulder Press |
| [Barbell Upright Row](https://www.simplyfitness.com/pages/barbell-upright-row) | Shoulders | Barbell Upright Row |
| [Bent-Over Lateral Raise](https://www.simplyfitness.com/pages/bent-over-lateral-raise) | Shoulders | Bent-Over Lateral Raise |
| [Cable One-Arm Lateral Raise](https://www.simplyfitness.com/pages/cable-one-arm-lateral-raise) | Shoulders | Cable One-Arm Lateral Raise |
| [Dumbbell Push Press](https://www.simplyfitness.com/pages/dumbbell-push-press) | Shoulders | Dumbbell Push Press |
| [Barbell Push Press](https://www.simplyfitness.com/pages/barbell-push-press) | Shoulders | Barbell Push Press |
| [Single-Arm Cable Front Raise](https://www.simplyfitness.com/pages/single-arm-cable-front-raise) | Shoulders | Single-Arm Cable Front Raise |
| [Barbell Front Raise](https://www.simplyfitness.com/pages/barbell-front-raise) | Shoulders | Barbell Front Raise |
| [Seated Barbell Shoulder Press](https://www.simplyfitness.com/pages/seated-barbell-shoulder-press) | Shoulders | Seated Barbell Shoulder Press |
| [Seated Behind the Neck Barbell Shoulder Press](https://www.simplyfitness.com/pages/seated-behind-the-neck-barbell-shoulder-press) | Shoulders | Seated Behind the Neck Barbell Shoulder Press |
| [Standing Barbell Shoulder Press](https://www.simplyfitness.com/pages/standing-barbell-shoulder-press) | Shoulders | Overhead Press |
| [Standing Behind the Neck Barbell Shoulder Press](https://www.simplyfitness.com/pages/standing-behind-the-neck-barbell-shoulder-press) | Shoulders | Standing Behind the Neck Barbell Shoulder Press |
| [Alternate Dumbbell Front Raise Neutral Grip](https://www.simplyfitness.com/pages/alternate-dumbbell-front-raise-neutral-grip) | Shoulders | Alternate Dumbbell Front Raise Neutral Grip |
| [One-Arm Low-Pulley Front Raise Neutral Grip](https://www.simplyfitness.com/pages/one-arm-low-pulley-front-raise-neutral-grip) | Shoulders | One-Arm Low-Pulley Front Raise Neutral Grip |
| [Two-Handed Dumbbell Front Raise](https://www.simplyfitness.com/pages/two-handed-dumbbell-front-raise) | Shoulders | Two-Handed Dumbbell Front Raise |
| [Barbell Curl](https://www.simplyfitness.com/pages/barbell-curl) | Biceps | Barbell Curl |
| [Alternating Dumbbell Curl](https://www.simplyfitness.com/pages/alternating-dumbbell-curl) | Biceps | Alternating Dumbbell Curl |
| [Rope Cable Curl](https://www.simplyfitness.com/pages/rope-cable-curl) | Biceps | Rope Cable Curl |
| [EZ Barbell Curl](https://www.simplyfitness.com/pages/ez-barbell-curl) | Biceps | EZ Barbell Curl |
| [EZ Barbell Preacher Curl](https://www.simplyfitness.com/pages/ez-barbell-preacher-curl) | Biceps | EZ Barbell Preacher Curl |
| [Hammer Curl](https://www.simplyfitness.com/pages/hammer-curl) | Biceps | Hammer Curl |
| [Incline Dumbbell Curl](https://www.simplyfitness.com/pages/incline-dumbbell-curl) | Biceps | Incline Dumbbell Curl |
| [Dumbbell Concentration Curl](https://www.simplyfitness.com/pages/dumbbell-concentration-curl) | Biceps | Dumbbell Concentration Curl |
| [Single-Arm Low Pulley Cable Curl](https://www.simplyfitness.com/pages/single-arm-low-pulley-cable-curl) | Biceps | Single-Arm Low Pulley Cable Curl |
| [Straight Bar Low Pulley Cable Curl](https://www.simplyfitness.com/pages/straight-bar-low-pulley-cable-curl) | Biceps | Straight Bar Low Pulley Cable Curl |
| [Standing High Pulley Cable Curl](https://www.simplyfitness.com/pages/standing-high-pulley-cable-curl) | Biceps | Standing High Pulley Cable Curl |
| [Seated Barbell Wrist Curl](https://www.simplyfitness.com/pages/seated-barbell-wrist-curl) | Biceps | Seated Barbell Wrist Curl |
| [Seated Barbell Wrist Extension](https://www.simplyfitness.com/pages/seated-barbell-wrist-extension) | Biceps | Seated Barbell Wrist Extension |
| [Reverse Barbell Curl](https://www.simplyfitness.com/pages/reverse-barbell-curl) | Biceps | Reverse Barbell Curl |
| [Lying Triceps Extension](https://www.simplyfitness.com/pages/lying-triceps-extension) | Triceps | Lying Triceps Extension |
| [Triceps Pressdown](https://www.simplyfitness.com/pages/triceps-pressdown) | Triceps | Triceps Pushdown |
| [Cable Rope Pushdown](https://www.simplyfitness.com/pages/cable-rope-puschdown) | Triceps | Cable Rope Pushdown |
| [Dumbbell Overhead Triceps Extension](https://www.simplyfitness.com/pages/dumbbell-overhead-triceps-extension) | Triceps | Dumbbell Overhead Triceps Extension |
| [Close Grip Bench Press](https://www.simplyfitness.com/pages/close-grip-bench-press) | Triceps | Close Grip Bench Press |
| [Kickback](https://www.simplyfitness.com/pages/kickback) | Triceps | Kickback |
| [Reverse Grip Cable Triceps Extension with Barbell](https://www.simplyfitness.com/pages/reverse-grip-cable-triceps-extension-with-barbell) | Triceps | Reverse Grip Cable Triceps Extension with Barbell |
| [Single-Arm Cable Triceps Extension](https://www.simplyfitness.com/pages/single-arm-cable-triceps-extension) | Triceps | Single-Arm Cable Triceps Extension |
| [Single-Arm Cable Triceps Extension with Supinated Grip](https://www.simplyfitness.com/pages/single-arm-cable-triceps-extension-with-supinated-grip) | Triceps | Single-Arm Cable Triceps Extension with Supinated Grip |
| [Lying Dumbbell Triceps Extension](https://www.simplyfitness.com/pages/lying-dumbbell-triceps-extension) | Triceps | Lying Dumbbell Triceps Extension |
| [Seated Barbell French Press](https://www.simplyfitness.com/pages/seated-barbell-french-press) | Triceps | Seated Barbell French Press |
| [Bench Dips](https://www.simplyfitness.com/pages/bench-dips) | Triceps | Bench Dips |
| [Parallel Dip Bar](https://www.simplyfitness.com/pages/parallel-dip-bar) | Triceps | Parallel Dip Bar |
| [Crunch](https://www.simplyfitness.com/pages/crunch) | Abdominals | Crunch |
| [Oblique Crunch](https://www.simplyfitness.com/pages/oblique-crunch) | Abdominals | Oblique Crunch |
| [Crunch Machine](https://www.simplyfitness.com/pages/crunch-machine) | Abdominals | Crunch Machine |
| [Rope Ab Pulldown](https://www.simplyfitness.com/pages/rope-ab-pulldown) | Abdominals | Rope Ab Pulldown |
| [Plank](https://www.simplyfitness.com/pages/plank) | Abdominals | Plank |
| [Hanging Leg Raise](https://www.simplyfitness.com/pages/hanging-leg-raise) | Abdominals | Hanging Leg Raise |
| [Bent Knee Reverse Crunch](https://www.simplyfitness.com/pages/bent-knee-reverse-crunch) | Abdominals | Bent Knee Reverse Crunch |
| [Long Arm Crunch](https://www.simplyfitness.com/pages/long-arm-crunch) | Abdominals | Long Arm Crunch |
| [Plank Get Ups](https://www.simplyfitness.com/pages/plank-get-ups) | Abdominals | Plank Get Ups |
| [Squat](https://www.simplyfitness.com/pages/squat) | Legs | Squat |
| [Leg Press](https://www.simplyfitness.com/pages/leg-press) | Legs | Leg Press |
| [Leg Extension](https://www.simplyfitness.com/pages/leg-extension) | Legs | Leg Extension |
| [Lunge](https://www.simplyfitness.com/pages/lunge) | Legs | Lunge |
| [Lying Leg Curl](https://www.simplyfitness.com/pages/lying-leg-curl) | Legs | Lying Leg Curl |
| [Hack Squat](https://www.simplyfitness.com/pages/hack-squat) | Legs | Hack Squat |
| [Seated Leg Curl](https://www.simplyfitness.com/pages/seated-leg-curl) | Legs | Seated Leg Curl |
| [Single Leg Extension](https://www.simplyfitness.com/pages/single-leg-extension) | Legs | Single Leg Extension |
| [Front Squat](https://www.simplyfitness.com/pages/front-squat) | Legs | Front Squat |
| [Dumbbell Stiff-Leg Deadlift](https://www.simplyfitness.com/pages/dumbbell-stiff-leg-deadlift) | Legs | Dumbbell Stiff-Leg Deadlift |
| [Barbell Stiff-Leg Deadlift](https://www.simplyfitness.com/pages/barbell-stiff-leg-deadlift) | Legs | Barbell Stiff-Leg Deadlift |
| [Dumbbell Goblet Squat](https://www.simplyfitness.com/pages/dumbbell-goblet-squat) | Legs | Dumbbell Goblet Squat |
| [Knee Tuck Jumps](https://www.simplyfitness.com/pages/knee-tuck-jumps) | Legs | Knee Tuck Jumps |
| [Burpees](https://www.simplyfitness.com/pages/burpees) | Legs | Burpees |
| [Bodyweight Squat](https://www.simplyfitness.com/pages/bodyweight-squat) | Legs | Bodyweight Squat |
| [1.5 Rep Bodyweight Squats](https://www.simplyfitness.com/pages/1-5-rep-bodyweight-squats) | Legs | 1.5 Rep Bodyweight Squats |
| [Medicine Ball Squat](https://www.simplyfitness.com/pages/medicine-ball-squat) | Legs | Medicine Ball Squat |
| [Barbell Bulgarian Split Squat](https://www.simplyfitness.com/pages/barbell-bulgarian-split-squat) | Legs | Barbell Bulgarian Split Squat |
| [Bodyweight Bulgarian Split Squat](https://www.simplyfitness.com/pages/bodyweight-bulgarian-split-squat) | Legs | Bodyweight Bulgarian Split Squat |
| [Mini-Band Air Squat](https://www.simplyfitness.com/pages/mini-band-air-squat) | Legs | Mini-Band Air Squat |
| [Jump Squat](https://www.simplyfitness.com/pages/jump-squat) | Legs | Jump Squat |
| [Wall Sit](https://www.simplyfitness.com/pages/wall-sit) | Legs | Wall Sit |
| [Medicine Ball Deadlift](https://www.simplyfitness.com/pages/medicine-ball-deadlift) | Legs | Medicine Ball Deadlift |
| [Single Leg Bodyweight Deadlift](https://www.simplyfitness.com/pages/single-leg-bodyweight-deadlift) | Legs | Single Leg Bodyweight Deadlift |
| [Kettlebell Sumo Deadlift](https://www.simplyfitness.com/pages/kettlebell-sumo-deadlift) | Legs | Kettlebell Sumo Deadlift |
| [Good Morning](https://www.simplyfitness.com/pages/good-morning) | Legs | Good Morning |
| [Bodyweight Glute Bridge](https://www.simplyfitness.com/pages/bodyweight-glute-bridge) | Legs | Bodyweight Glute Bridge |
| [Single Leg Glute Bridge](https://www.simplyfitness.com/pages/single-leg-glute-bridge) | Legs | Single Leg Glute Bridge |
| [Banded Glute Bridge](https://www.simplyfitness.com/pages/banded-glute-bridge) | Legs | Banded Glute Bridge |
| [Duck Walk](https://www.simplyfitness.com/pages/duck-walk) | Legs | Duck Walk |
| [Bird Dog](https://www.simplyfitness.com/pages/bird-dog) | Legs | Bird Dog |
| [Groiners](https://www.simplyfitness.com/pages/groiners) | Legs | Groiners |
| [Fire Hydrants](https://www.simplyfitness.com/pages/fire-hydrants) | Legs | Fire Hydrants |
| [Smith Machine Hip Thrust](https://www.simplyfitness.com/pages/smith-machine-hip-thrust) | Legs | Smith Machine Hip Thrust |
| [Barbell Hip Thrust](https://www.simplyfitness.com/pages/barbell-hip-thrust) | Legs | Barbell Hip Thrust |
| [Band Seated Hip Abduction](https://www.simplyfitness.com/pages/band-seated-hip-abduction) | Legs | Band Seated Hip Abduction |
| [Seated Hip Abduction Machine](https://www.simplyfitness.com/pages/seated-hip-abduction-machine) | Legs | Seated Hip Abduction Machine |
| [Standing Cable Abduction](https://www.simplyfitness.com/pages/standing-cable-abduction) | Legs | Standing Cable Abduction |
| [Bodyweight Frog Pump](https://www.simplyfitness.com/pages/bodyweight-frog-pump) | Legs | Bodyweight Frog Pump |
| [Smith Machine Frog Pump](https://www.simplyfitness.com/pages/smith-machine-frog-pump) | Legs | Smith Machine Frog Pump |
| [Banded Clams](https://www.simplyfitness.com/pages/banded-clams) | Legs | Banded Clams |
| [Side Lying Leg Raise](https://www.simplyfitness.com/pages/side-lying-leg-raise) | Legs | Side Lying Leg Raise |
| [Glute Ham Raise](https://www.simplyfitness.com/pages/glute-ham-raise) | Legs | Glute Ham Raise |
| [Dumbbell Step Up](https://www.simplyfitness.com/pages/dumbbell-step-up) | Legs | Dumbbell Step Up |
| [Lateral Mini-Band Walk](https://www.simplyfitness.com/pages/lateral-mini-band-walk) | Legs | Lateral Mini-Band Walk |
| [Standing Knee Raise](https://www.simplyfitness.com/pages/standing-knee-raise) | Legs | Standing Knee Raise |
| [Kettlebell Swings](https://www.simplyfitness.com/pages/kettlebell-swings) | Legs | Kettlebell Swings |
| [Standing Cable Kickback](https://www.simplyfitness.com/pages/standing-cable-kickback) | Legs | Standing Cable Kickback |
| [Donkey Kicks](https://www.simplyfitness.com/pages/donkey-kicks) | Legs | Donkey Kicks |
| [Side Lying Hip Raise](https://www.simplyfitness.com/pages/side-lying-hip-raise) | Legs | Side Lying Hip Raise |
| [Squat Sit to Reach](https://www.simplyfitness.com/pages/squat-sit-to-reach) | Legs | Squat Sit to Reach |
| [Seated Calf Raise](https://www.simplyfitness.com/pages/seated-calf-raise) | Calves | Seated Calf Raise |
| [Standing Calf Raise](https://www.simplyfitness.com/pages/standing-calf-raise) | Calves | Standing Calf Raise |
