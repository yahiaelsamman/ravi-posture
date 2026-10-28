# Ravi's moves

Every move has to work at a desk in an office, a library or at home: seated or standing beside the chair, with
no floor work, no equipment and nothing loud. The 24 moves in [`shared/moves.json`](../shared/moves.json) come
from office-ergonomics guides (Mayo Clinic's desk stretches, NHS and Chartered Society of Physiotherapy chair
routines, Hinge Health's desk set), physiotherapy programmes for desk posture ("upper crossed syndrome"), and
hand-therapy and sit-break research. They are everyday mobility exercises, not treatment: skip anything that
hurts, and see a physio for pain that sticks around.

| Move | Area | Why it's here |
| --- | --- | --- |
| Chin tucks | Neck | Deep neck flexor work against forward head posture; a staple of desk-posture programmes. |
| Thoracic extension | Upper back | Counters the slump by extending the mid-back over the backrest. |
| Walkaround | Whole body | Light walking breaks during long sitting lower post-meal glucose more than standing breaks do. |
| Shoulder blade squeeze | Upper back | Mid and lower trapezius activation for rounded shoulders. |
| Doorway chest stretch | Chest | Stretches the pecs that shorten with keyboard work. A wall edge or bookshelf works without a door. |
| Neck side stretch | Neck | Upper trapezius stretch, paired with strengthening in posture programmes. |
| Stand and reach | Spine | Gets you up and lengthens the trunk and sides. |
| Seated twist | Spine | Rotation for a stiff thoracic spine, done in the chair. |
| Wrist and forearm stretch | Wrists | Flexor and extensor stretch for typing and mouse use. |
| 20-20-20 eye break | Eyes | Relaxes focusing effort after close screen work. |
| Hip flexor stretch | Hips | Hip flexors shorten with sitting; standing version, no floor. |
| Calf raises | Legs | Calf muscle pump for circulation after sitting. |
| **Chair angels** | Upper back | Wall angels done against the backrest. Lower trapezius and serratus work like this cut neck and shoulder pain in office workers (Andersen et al., 2014), and mid/lower trapezius strengthening plus neck stretching beat other combinations for upper crossed syndrome (Bae et al., 2016). |
| **Levator scapulae stretch** | Neck | The other half of that 2016 programme: the stretch for the tight spot where the neck meets the shoulder blade. |
| **Shoulder rolls** | Shoulders | Hinge Health and Mayo Clinic desk routines; eases upper trapezius tension without anyone noticing. |
| **Seated cat-cow** | Lower back | Seated pelvic tilts and back extension from chair routines; moves the lumbar spine through its range. |
| **Seated figure-4 stretch** | Hips | Glute and piriformis stretch from desk hip routines; works in any chair. |
| **Seated hamstring stretch** | Legs | Hamstrings tighten with sitting and pull on the lower back; heel-down version needs no floor. |
| **Sit-to-stands** | Legs | Mayo Clinic's "chair squats": a quiet strength break that also gets you out of the chair. |
| **Desk push-ups** | Chest | Mayo Clinic's physio-led desk set; upper-body strength against a sturdy desk. |
| **Tendon glides** | Hands | Hand-therapy sequence (straight, hook, fist) that keeps the finger tendons gliding. Evidence for treating carpal tunnel is limited, so it's here as a typing break, not a fix. |
| **Brügger relief position** | Chest | Classic physio microbreak for desk posture: palms forward, chest up, shoulders back and down. |
| **Belly breathing** | Breathing | Slow diaphragmatic breathing, about 6 breaths a minute. Completely silent, so it works in a library. |
| **Ankle pumps** | Ankles | Under-the-desk calf pump from NHS and council desk sheets; invisible to everyone else. |

## Sources

- Mayo Clinic, [Office stretches](https://www.mayoclinic.org/healthy-lifestyle/adult-health/in-depth/office-stretches/art-20046041)
  and [Don't just sit there: exercises for the office](https://www.mayoclinichealthsystem.org/hometown-health/speaking-of-health/dont-just-sit-there-exercises-for-the-office)
- Hinge Health, [12 best office exercises and stretches to do at your desk](https://www.hingehealth.com/resources/articles/exercises-to-do-at-your-desk)
- NHS [sitting exercises](https://www.oxfordhealth.nhs.uk/wp-content/uploads/2020/04/NHS-sitting-exercises.pdf) and the
  CSP [Fit for Work leaflet](https://casestudies.csp.org.uk/system/files/fit_for_work_leaflet_english.pdf)
- Andersen et al. 2014, [Effect of scapular function training on chronic pain in the neck/shoulder region](https://pmc.ncbi.nlm.nih.gov/articles/PMC4000422/), J Occup Rehabil
- Bae et al. 2016, [Effects of an exercise programme for upper crossed syndrome](https://www.jstage.jst.go.jp/article/jpts/28/5/28_jpts-2016-012/_article), J Phys Ther Sci
- Queen's University, [Tendon and nerve gliding exercises](https://elentra.healthsci.queensu.ca/community/carpaltunnelsyndrome:treatment/conservative/gliding_exercises) (and their limits)
- Brocklebank, Andrews & Page 2017, [The acute effects of breaking up seated office work with standing or light-intensity walking on interstitial glucose](https://read.qxmd.com/read/28422556/the-acute-effects-of-breaking-up-seated-office-work-with-standing-or-light-intensity-walking-on-interstitial-glucose-concentration-a-randomized-crossover-trial), J Phys Act Health

## How Ravi shows them

Ravi has a skeleton (`shared/card.html`, "Ravi's skeleton"). His body is the root bone and pivots at the hips;
each arm and leg is two bones of fixed length solved with two-bone IK, so limbs bend at the elbow and knee
instead of stretching. A pose is a short loop of keyframes saying where the hands and feet go, plus a hint for
which way each elbow and knee bends. Feet stay planted, hands can be pinned to a desk or the knees, hands open
and close, shoes roll onto the toes, and on one-sided stretches Ravi switches sides when the timer does.

To add a move: add it to `moves.json` with a `pose` name, then add that pose to `POSES` in `card.html`.
