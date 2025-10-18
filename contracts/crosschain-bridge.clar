;; ------------------------------------------------------------
;; CrossChain Bridge - Cross-Chain Liquidity Bridge (Clarity v2)
;; ------------------------------------------------------------
;; - Wrapped token: wBTC (fungible token).
;; - Off-chain BTC locked -> Oracle calls `mint` with unique request-id -> contract mints wBTC.
;; - On-chain burn -> user calls `burn` to burn wBTC and create a burn-request record;
;;   off-chain relayer / custodial operator watches burn-requests and executes BTC release.
;; - Replay protection: each external request-id can be processed only once.
;; - Admin/Oracle: owner sets trusted oracle; oracle is the only actor allowed to mint.
;; - Fees: optional burn fee (BPS) credited to treasury.
;; - Pause switch for emergency response.
;; ------------------------------------------------------------

(define-fungible-token wBTC)

;; -------------------- Errors --------------------
(define-constant ERR-UNAUTHORIZED   (err u100))
(define-constant ERR-BAD-ARGS       (err u101))
(define-constant ERR-ALREADY        (err u102))
(define-constant ERR-NOT-FOUND      (err u103))
(define-constant ERR-INSUFFICIENT   (err u104))
(define-constant ERR-PAUSED         (err u105))

;; -------------------- Config / State --------------------
(define-data-var owner      principal tx-sender) ;; set at deploy
(define-data-var oracle     principal tx-sender) ;; trusted oracle/operator
(define-data-var paused     bool false)          ;; emergency switch
(define-data-var treasury   principal tx-sender) ;; treasury recipient for fees
(define-data-var burn-fee-bps uint u50)          ;; default 0.5% fee (50 bps)

;; processed external request-ids (e.g., Bitcoin lock txids) -> true
(define-map processed-requests
  { req: (buff 32) } ;; external request id (32-byte buffer)
  { processed: bool })

;; Burn requests created on-chain when users burn wBTC to redeem BTC off-chain.
(define-data-var next-burn-id uint u1)
(define-map burn-requests
  { id: uint }
  {
    who: principal,
    amount: uint,         ;; gross amount burned
    fee: uint,            ;; fee taken (STX units of token units)
    timestamp: uint,
    processed: bool       ;; set true by oracle/off-chain operator after BTC release
  })

;; -------------------- Helpers --------------------
(define-read-only (is-owner (p principal)) (is-eq p (var-get owner)))
(define-read-only (is-oracle (p principal)) (is-eq p (var-get oracle)))
(define-read-only (now) u0)

(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

;; -------------------- Admin --------------------
(define-public (set-oracle (who principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (is-some (some who)) ERR-BAD-ARGS)
    (var-set oracle who)
    (ok who)))

(define-public (set-treasury (who principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (is-some (some who)) ERR-BAD-ARGS)
    (var-set treasury who)
    (ok who)))

(define-public (set-burn-fee-bps (bps uint))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (<= bps u1000) ERR-BAD-ARGS) ;; cap at 10%
    (var-set burn-fee-bps bps)
    (ok bps)))

(define-public (pause)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set paused true)
    (ok true)))

(define-public (unpause)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set paused false)
    (ok true)))

;; -------------------- Mint (oracle-only) --------------------
;; Mint wrapped tokens when off-chain custody confirms incoming BTC lock.
;; `req` is a unique external request id (e.g., BTC txid hashed to 32 bytes).
(define-public (mint (req (buff 32)) (to principal) (amount uint))
  (begin
    (asserts! (not (var-get paused)) ERR-PAUSED)
    (asserts! (is-oracle tx-sender) ERR-UNAUTHORIZED)
    (asserts! (> amount u0) ERR-BAD-ARGS)
    (asserts! (is-some (some req)) ERR-BAD-ARGS)
    (asserts! (is-some (some to)) ERR-BAD-ARGS)
    ;; ensure request-id not processed already
    (match (map-get? processed-requests { req: req })
      processed-request 
      (if (get processed processed-request)
        (err u1)
        (begin
          (map-set processed-requests { req: req } { processed: true })
          (asserts! (is-ok (ft-mint? wBTC amount to)) ERR-INSUFFICIENT)
          (ok { minted: amount, to: to })))
      (begin
        (map-set processed-requests { req: req } { processed: true })
        (asserts! (is-ok (ft-mint? wBTC amount to)) ERR-INSUFFICIENT)
        (ok { minted: amount, to: to })))))

;; -------------------- Burn (user-facing) --------------------
;; Burn wBTC to request off-chain BTC release. Creates an on-chain burn-request
;; for relayers/operators to process.
(define-public (burn (amount uint))
  (let 
    ((fee (/ (* amount (var-get burn-fee-bps)) u10000))
     (net (- amount fee)))
    (begin
      (asserts! (not (var-get paused)) ERR-PAUSED)
      (asserts! (> amount u0) ERR-BAD-ARGS)
      (asserts! (> net u0) ERR-BAD-ARGS)
      (match (ft-burn? wBTC amount tx-sender)
        ok-burn
        (let ((id (var-get next-burn-id)))
          (begin
            (map-set burn-requests { id: id }
              {
                who: tx-sender,
                amount: amount,
                fee: fee,
                timestamp: (now),
                processed: false
              })
            (var-set next-burn-id (+ id u1))
            (if (> fee u0)
              (match (ft-mint? wBTC fee (var-get treasury))
                ok-mint (ok { burn-id: id, burned: amount, fee: fee, net: net })
                err-mint (err u1))
              (ok { burn-id: id, burned: amount, fee: fee, net: net }))))
        err-burn (err u1)))))

;; -------------------- Mark burn processed (oracle/operator) --------------------
;; After off-chain BTC release, oracle marks burn-request processed to avoid double servicing.
(define-public (confirm-burn (id uint) (external-proof (buff 32)))
  (begin
    (asserts! (is-oracle tx-sender) ERR-UNAUTHORIZED)
    (match (map-get? burn-requests { id: id })
      burn-request
        (begin
          (asserts! (not (get processed burn-request)) ERR-ALREADY)
          (asserts! (is-some (some burn-request)) ERR-BAD-ARGS)
          (let 
            ((who (get who burn-request))
             (amount (get amount burn-request))
             (fee (get fee burn-request))
             (timestamp (get timestamp burn-request)))
            (asserts! (is-some (some who)) ERR-BAD-ARGS)
            (asserts! (is-some (some amount)) ERR-BAD-ARGS)
            (asserts! (is-some (some fee)) ERR-BAD-ARGS)
            (asserts! (is-some (some timestamp)) ERR-BAD-ARGS)
            (map-set burn-requests { id: id }
              {
                who: who,
                amount: amount,
                fee: fee,
                timestamp: timestamp,
                processed: true
              })
            (ok { id: id, who: who, amount: amount })))
      (err u1))))

;; -------------------- Views --------------------
(define-read-only (get-burn-request (id uint))
  (match (map-get? burn-requests { id: id })
    burn-request (ok burn-request)
    (err u1)))

(define-read-only (is-request-processed (req (buff 32)))
  (match (map-get? processed-requests { req: req })
    request (get processed request)
    false))

(define-read-only (get-wbtc-balance (who principal))
  (ft-get-balance wBTC who))

(define-read-only (get-next-burn-id) (ok (var-get next-burn-id)))

(define-read-only (bridge-stats)
  {
    paused: (var-get paused),
    oracle: (var-get oracle),
    treasury: (var-get treasury),
    burn-fee-bps: (var-get burn-fee-bps),
    next-burn-id: (var-get next-burn-id)
  })
