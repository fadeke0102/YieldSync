;; YieldSync - Cross-chain Yield Aggregator
;; Bridges Bitcoin DeFi yields with traditional DeFi protocols via Stacks

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_POOL_NOT_FOUND (err u103))
(define-constant ERR_ALREADY_EXISTS (err u104))
(define-constant ERR_PAUSED (err u105))

;; Added validation constants for input bounds
(define-constant MAX_APY u10000) ;; 100% APY in basis points
(define-constant MIN_DEPOSIT_LIMIT u1000000) ;; 1 STX minimum
(define-constant MAX_DEPOSIT_LIMIT u100000000000) ;; 1M STX maximum
(define-constant MAX_POOL_NAME_LENGTH u50)

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var total-value-locked uint u0)
(define-data-var next-pool-id uint u1)

;; Data Maps
(define-map yield-pools 
  { pool-id: uint }
  {
    name: (string-ascii 50),
    apy: uint,
    tvl: uint,
    active: bool,
    min-deposit: uint
  }
)

(define-map user-deposits
  { user: principal, pool-id: uint }
  {
    amount: uint,
    deposit-block: uint,
    last-claim-block: uint
  }
)

(define-map user-total-deposits
  { user: principal }
  { total-amount: uint }
)

(define-map pool-rewards
  { pool-id: uint }
  { reward-rate: uint, total-rewards: uint }
)

;; Read-only functions
(define-read-only (get-contract-info)
  {
    paused: (var-get contract-paused),
    tvl: (var-get total-value-locked),
    total-pools: (- (var-get next-pool-id) u1)
  }
)

(define-read-only (get-pool-info (pool-id uint))
  (map-get? yield-pools { pool-id: pool-id })
)

(define-read-only (get-user-deposit (user principal) (pool-id uint))
  (map-get? user-deposits { user: user, pool-id: pool-id })
)

(define-read-only (get-user-total-deposits (user principal))
  (default-to { total-amount: u0 } (map-get? user-total-deposits { user: user }))
)

(define-read-only (calculate-rewards (user principal) (pool-id uint))
  (let (
    (deposit-info (map-get? user-deposits { user: user, pool-id: pool-id }))
    (pool-info (map-get? yield-pools { pool-id: pool-id }))
  )
    (match deposit-info
      deposit-data
      (match pool-info
        pool-data
        (let (
          (blocks-since-last-claim (- block-height (get last-claim-block deposit-data)))
          (deposit-amount (get amount deposit-data))
          (apy (get apy pool-data))
        )
          (ok (/ (* deposit-amount apy blocks-since-last-claim) u52560000)) ;; Approximate blocks per year
        )
        (err ERR_POOL_NOT_FOUND)
      )
      (err ERR_INSUFFICIENT_BALANCE)
    )
  )
)

;; Admin functions
(define-public (toggle-contract-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok true)
  )
)

(define-public (create-yield-pool (name (string-ascii 50)) (apy uint) (min-deposit uint))
  (let (
    (pool-id (var-get next-pool-id))
    ;; Added input validation variables
    (validated-name (if (> (len name) u0) name "Default Pool"))
    (validated-apy (if (<= apy MAX_APY) apy u500)) ;; Default 5% if invalid
    (validated-min-deposit (if (and (>= min-deposit MIN_DEPOSIT_LIMIT) (<= min-deposit MAX_DEPOSIT_LIMIT)) min-deposit MIN_DEPOSIT_LIMIT))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-none (map-get? yield-pools { pool-id: pool-id })) ERR_ALREADY_EXISTS)
    ;; Added input validation assertions
    (asserts! (> (len name) u0) ERR_INVALID_AMOUNT)
    (asserts! (<= apy MAX_APY) ERR_INVALID_AMOUNT)
    (asserts! (and (>= min-deposit MIN_DEPOSIT_LIMIT) (<= min-deposit MAX_DEPOSIT_LIMIT)) ERR_INVALID_AMOUNT)

    (map-set yield-pools
      { pool-id: pool-id }
      {
        ;; Using validated inputs instead of raw inputs
        name: validated-name,
        apy: validated-apy,
        tvl: u0,
        active: true,
        min-deposit: validated-min-deposit
      }
    )

    (map-set pool-rewards
      { pool-id: pool-id }
      ;; Using validated APY
      { reward-rate: validated-apy, total-rewards: u0 }
    )

    (var-set next-pool-id (+ pool-id u1))
    (ok pool-id)
  )
)

(define-public (update-pool-apy (pool-id uint) (new-apy uint))
  (let (
    ;; Added input validation for pool-id and new-apy
    (validated-pool-id (if (and (>= pool-id u1) (< pool-id (var-get next-pool-id))) pool-id u1))
    (validated-apy (if (<= new-apy MAX_APY) new-apy u500))
    (pool-info (unwrap! (map-get? yield-pools { pool-id: validated-pool-id }) ERR_POOL_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    ;; Added validation assertions
    (asserts! (and (>= pool-id u1) (< pool-id (var-get next-pool-id))) ERR_POOL_NOT_FOUND)
    (asserts! (<= new-apy MAX_APY) ERR_INVALID_AMOUNT)

    (map-set yield-pools
      ;; Using validated pool-id
      { pool-id: validated-pool-id }
      (merge pool-info { apy: validated-apy })
    )

    (map-set pool-rewards
      ;; Using validated inputs
      { pool-id: validated-pool-id }
      { reward-rate: validated-apy, total-rewards: u0 }
    )

    (ok true)
  )
)

;; User functions
(define-public (deposit-to-pool (pool-id uint) (amount uint))
  (let (
    ;; Added input validation for pool-id and amount
    (validated-pool-id (if (and (>= pool-id u1) (< pool-id (var-get next-pool-id))) pool-id u1))
    (validated-amount (if (and (> amount u0) (<= amount MAX_DEPOSIT_LIMIT)) amount u0))
    (pool-info (unwrap! (map-get? yield-pools { pool-id: validated-pool-id }) ERR_POOL_NOT_FOUND))
    (current-deposit (default-to { amount: u0, deposit-block: u0, last-claim-block: u0 } 
                     (map-get? user-deposits { user: tx-sender, pool-id: validated-pool-id })))
    (user-total (get total-amount (get-user-total-deposits tx-sender)))
  )
    (asserts! (not (var-get contract-paused)) ERR_PAUSED)
    (asserts! (get active pool-info) ERR_POOL_NOT_FOUND)
    ;; Added input validation assertions
    (asserts! (and (>= pool-id u1) (< pool-id (var-get next-pool-id))) ERR_POOL_NOT_FOUND)
    (asserts! (and (> amount u0) (<= amount MAX_DEPOSIT_LIMIT)) ERR_INVALID_AMOUNT)
    (asserts! (>= validated-amount (get min-deposit pool-info)) ERR_INVALID_AMOUNT)

    ;; Transfer STX from user to contract
    (try! (stx-transfer? validated-amount tx-sender (as-contract tx-sender)))

    ;; Update user deposit
    (map-set user-deposits
      ;; Using validated pool-id
      { user: tx-sender, pool-id: validated-pool-id }
      {
        amount: (+ (get amount current-deposit) validated-amount),
        deposit-block: block-height,
        last-claim-block: block-height
      }
    )

    ;; Update user total deposits
    (map-set user-total-deposits
      { user: tx-sender }
      { total-amount: (+ user-total validated-amount) }
    )

    ;; Update pool TVL
    (map-set yield-pools
      ;; Using validated pool-id
      { pool-id: validated-pool-id }
      (merge pool-info { tvl: (+ (get tvl pool-info) validated-amount) })
    )

    ;; Update contract TVL
    (var-set total-value-locked (+ (var-get total-value-locked) validated-amount))

    (ok true)
  )
)

(define-public (withdraw-from-pool (pool-id uint) (amount uint))
  (let (
    ;; Added input validation for pool-id and amount
    (validated-pool-id (if (and (>= pool-id u1) (< pool-id (var-get next-pool-id))) pool-id u1))
    (validated-amount (if (and (> amount u0) (<= amount MAX_DEPOSIT_LIMIT)) amount u0))
    (pool-info (unwrap! (map-get? yield-pools { pool-id: validated-pool-id }) ERR_POOL_NOT_FOUND))
    (deposit-info (unwrap! (map-get? user-deposits { user: tx-sender, pool-id: validated-pool-id }) ERR_INSUFFICIENT_BALANCE))
    (user-total (get total-amount (get-user-total-deposits tx-sender)))
  )
    (asserts! (not (var-get contract-paused)) ERR_PAUSED)
    ;; Added input validation assertions
    (asserts! (and (>= pool-id u1) (< pool-id (var-get next-pool-id))) ERR_POOL_NOT_FOUND)
    (asserts! (and (> amount u0) (<= amount MAX_DEPOSIT_LIMIT)) ERR_INVALID_AMOUNT)
    (asserts! (>= (get amount deposit-info) validated-amount) ERR_INSUFFICIENT_BALANCE)

    ;; Transfer STX from contract to user
    (try! (as-contract (stx-transfer? validated-amount tx-sender tx-sender)))

    ;; Update user deposit
    (map-set user-deposits
      ;; Using validated pool-id
      { user: tx-sender, pool-id: validated-pool-id }
      (merge deposit-info { amount: (- (get amount deposit-info) validated-amount) })
    )

    ;; Update user total deposits
    (map-set user-total-deposits
      { user: tx-sender }
      { total-amount: (- user-total validated-amount) }
    )

    ;; Update pool TVL
    (map-set yield-pools
      ;; Using validated pool-id
      { pool-id: validated-pool-id }
      (merge pool-info { tvl: (- (get tvl pool-info) validated-amount) })
    )

    ;; Update contract TVL
    (var-set total-value-locked (- (var-get total-value-locked) validated-amount))

    (ok true)
  )
)

(define-public (claim-rewards (pool-id uint))
  (let (
    (rewards (unwrap! (calculate-rewards tx-sender pool-id) ERR_INSUFFICIENT_BALANCE))
    (deposit-info (unwrap! (map-get? user-deposits { user: tx-sender, pool-id: pool-id }) ERR_INSUFFICIENT_BALANCE))
  )
    (asserts! (not (var-get contract-paused)) ERR_PAUSED)
    (asserts! (> rewards u0) ERR_INVALID_AMOUNT)

    ;; Transfer rewards to user
    (try! (as-contract (stx-transfer? rewards tx-sender tx-sender)))

    ;; Update last claim block
    (map-set user-deposits
      { user: tx-sender, pool-id: pool-id }
      (merge deposit-info { last-claim-block: block-height })
    )

    (ok rewards)
  )
)

;; Emergency functions
(define-public (emergency-withdraw)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (var-get contract-paused) ERR_UNAUTHORIZED)

    (try! (as-contract (stx-transfer? (stx-get-balance (as-contract tx-sender)) tx-sender CONTRACT_OWNER)))
    (ok true)
  )
)
