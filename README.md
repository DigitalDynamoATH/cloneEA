# MT5 Signal Copier System

Σύστημα αντιγραφής σημάτων για MetaTrader 5 που επιτρέπει την αντιγραφή trades από μια EA σε άλλη με custom stop loss και take profit settings.

## Περιγραφή

Αυτό το σύστημα αποτελείται από δύο Expert Advisors:

1. **SignalSender.mq5** - Παίρνει σήματα από την αγορασμένη EA και τα στέλνει
2. **SignalReceiver.mq5** - Παίρνει τα σήματα και ανοίγει trades με δικά σου settings

## Εγκατάσταση

### Βήμα 1: Αντιγραφή αρχείων
1. Αντιγράψτε τα `.mq5` αρχεία στον φάκελο `MQL5/Experts/` του MetaTrader 5
2. Μεταγλωττίστε τα αρχεία στο MetaEditor (F7)

### Βήμα 1.5: VPS Setup (Αν χρησιμοποιείτε VPS)
**Για ίδιο VPS (Προτεινόμενο):**
- Ρυθμίστε `Use_Global_Variables = true` και στα δύο EAs
- Το `Global_Variable_Prefix` πρέπει να είναι ίδιο και στα δύο
- Δείτε το `VPS_ΟΔΗΓΟΣ_ΕΛΛΗΝΙΚΑ.txt` για λεπτομέρειες

**Για διαφορετικά VPS:**
- Ρυθμίστε `Use_Global_Variables = false` και στα δύο
- Χρησιμοποιήστε network folder ή cloud sync (Dropbox/OneDrive)
- Δείτε το `VPS_Setup_Guide.md` για λεπτομέρειες

### Βήμα 2: Ρύθμιση SignalSender (Account 1 - με την αγορασμένη EA)

1. Βρείτε το Magic Number της αγορασμένης EA σας:
   - Ανοίξτε την αγορασμένη EA
   - Κοιτάξτε στα settings της το Magic Number
   - Αν δεν έχει, κοιτάξτε το Comment των trades που ανοίγει

2. Ανοίξτε το **SignalSender.mq5** στο chart:
   - Ρυθμίστε το `EA_Magic_Number` με το magic number της αγορασμένης EA
   - `Use_Global_Variables`: `true` (για ίδιο VPS) ή `false` (για διαφορετικά VPS)
   - `Global_Variable_Prefix`: "MT5Signal_" (πρέπει να ταιριάζει με το Receiver)

### Βήμα 3: Ρύθμιση SignalReceiver (Account 2 - δικό σου account)

1. Ανοίξτε το **SignalReceiver.mq5** στο chart:
   - `Stop_Loss_Points`: Βάλτε πόσα points θέλετε για stop loss (π.χ. 50)
   - `Take_Profit_Points`: Βάλτε πόσα points θέλετε για take profit (π.χ. 100)
   - `Volume_Multiplier`: Πολλαπλασιαστής όγκου (1.0 = ίδιος όγκος)
   - `Magic_Number`: Magic number για τα δικά σου trades
   - `Use_Custom_SL_TP`: true (για να χρησιμοποιεί τα δικά σου SL/TP)
   - `Use_Global_Variables`: `true` (για ίδιο VPS) ή `false` (για διαφορετικά VPS)
   - `Global_Variable_Prefix`: "MT5Signal_" (πρέπει να ταιριάζει με το Sender)

## Πώς λειτουργεί

1. Η **SignalSender** παρακολουθεί συνεχώς τα ανοιχτά positions
2. Όταν βρει νέο trade από την αγορασμένη EA (με το συγκεκριμένο magic number), δημιουργεί ένα σήμα
3. Το σήμα αποθηκεύεται σε ένα αρχείο (`Signals/signal.txt`)
4. Η **SignalReceiver** διαβάζει το αρχείο και όταν βρει νέο σήμα, ανοίγει trade
5. Το trade ανοίγεται με τα **δικά σου** stop loss και take profit settings

## Σημαντικές Σημειώσεις

- **Και οι δύο EAs πρέπει να τρέχουν ταυτόχρονα**
- **Για VPS:** Αν τα accounts είναι στο ίδιο VPS, χρησιμοποιήστε `Use_Global_Variables = true` για γρηγορότερη επικοινωνία
- Το αρχείο signal.txt βρίσκεται στον κοινό φάκελο του MT5 (`MQL5/Files/Common/Signals/`)
- Αν τα accounts είναι σε διαφορετικά VPS/terminals, χρησιμοποιήστε network sharing ή cloud storage (Dropbox/OneDrive)
- Βεβαιωθείτε ότι το `EA_Magic_Number` στο SignalSender ταιριάζει με το magic number της αγορασμένης EA
- Το `Global_Variable_Prefix` πρέπει να είναι **ίδιο** και στα δύο EAs

## Αντιμετώπιση Προβλημάτων

### Το SignalReceiver δεν ανοίγει trades
- Ελέγξτε ότι το αρχείο signal.txt δημιουργείται (στο `MQL5/Files/Common/Signals/`)
- Ελέγξτε τα logs στο MetaTrader (View → Strategy Tester → Journal)
- Βεβαιωθείτε ότι το AutoTrading είναι ενεργοποιημένο

### Λάθος Magic Number
- Κοιτάξτε τα properties των trades που ανοίγει η αγορασμένη EA
- Μερικές EAs βάζουν το magic number στο Comment αντί για Magic Number field

### Volume errors
- Ελέγξτε ότι το volume είναι πολλαπλάσιο του minimum step
- Ρυθμίστε το `Volume_Multiplier` αν χρειάζεται

## Προχωρημένες Ρυθμίσεις

### Αλλαγή τρόπου επικοινωνίας
Αν θέλετε να χρησιμοποιήσετε άλλο τρόπο επικοινωνίας (π.χ. sockets, global variables), μπορείτε να τροποποιήσετε τις συναρτήσεις `SendSignal()` και `CheckForNewSignals()`.

### Filling Types
Αν έχετε προβλήματα με το opening των trades, δοκιμάστε να αλλάξετε το `SetTypeFilling()` στο SignalReceiver:
- `ORDER_FILLING_FOK` - Fill or Kill
- `ORDER_FILLING_IOC` - Immediate or Cancel
- `ORDER_FILLING_RETURN` - Return

## Support

Για οποιαδήποτε ερώτηση ή πρόβλημα, ελέγξτε τα logs του MetaTrader 5.

