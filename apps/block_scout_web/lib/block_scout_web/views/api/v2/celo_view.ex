defmodule BlockScoutWeb.API.V2.CeloView do
  require Logger

  import Explorer.Chain.Celo.Helper, only: [is_epoch_block_number: 1]

  alias Ecto.Association.NotLoaded

  alias BlockScoutWeb.API.V2.{Helper, TokenView, TransactionView}
  alias Explorer.Chain
  alias Explorer.Chain.Cache.CeloCoreContracts
  alias Explorer.Chain.Celo.Helper, as: CeloHelper
  alias Explorer.Chain.Celo.{ElectionReward, EpochReward, Reader}
  alias Explorer.Chain.{Block, Transaction}

  @address_params [
    necessity_by_association: %{
      :names => :optional,
      :smart_contract => :optional,
      :proxy_implementations => :optional
    },
    api?: true
  ]

  def render("celo_epoch_distributions.json", block) do
    block
    |> Map.get(:celo_epoch_reward)
    |> prepare_epoch_distributions()
  end

  def render("celo_aggregated_election_rewards.json", %Block{} = block)
      when is_epoch_block_number(block.number) do
    aggregated_election_rewards = Reader.block_hash_to_aggregated_election_rewards_by_type(block.hash, api?: true)

    # Return a map with all possible election reward types, even if they are not
    # present in the database.
    ElectionReward.types()
    |> Map.new(&{&1, 0})
    |> Map.merge(aggregated_election_rewards)
  end

  def render("celo_aggregated_election_rewards.json", %Block{} = _block),
    do: nil

  def render("celo_base_fee.json", %Block{} = block) do
    # For the blocks, where both FeeHandler and Governance contracts aren't
    # deployed, the base fee is not burnt, but refunded to transaction sender,
    # so we return nil in this case.

    base_fee = Block.burnt_fees(block.transactions, block.base_fee_per_gas)

    fee_handler_base_fee_breakdown(
      base_fee,
      block.number
    ) ||
      governance_base_fee_breakdown(
        base_fee,
        block.number
      )
  end

  def render("celo_election_rewards.json", %{
        rewards: rewards,
        next_page_params: next_page_params
      }) do
    %{
      "items" => Enum.map(rewards, &prepare_election_reward/1),
      "next_page_params" => next_page_params
    }
  end

  def prepare_epoch_distributions(%EpochReward{} = epoch_reward) do
    %EpochReward{
      reserve_bolster_transfer: reserve_bolster_transfer,
      community_transfer: community_transfer,
      carbon_offsetting_transfer: carbon_offsetting_transfer
    } = EpochReward.load_token_transfers(epoch_reward)

    Map.new(
      [
        reserve_bolster_transfer: reserve_bolster_transfer,
        community_transfer: community_transfer,
        carbon_offsetting_transfer: carbon_offsetting_transfer
      ],
      fn {field, token_transfer} ->
        token_transfer_json =
          token_transfer &&
            TransactionView.render(
              "token_transfer.json",
              %{token_transfer: token_transfer, conn: nil}
            )

        {field, token_transfer_json}
      end
    )
  end

  def prepare_epoch_distributions(_epoch_reward), do: nil

  def prepare_election_reward(%ElectionReward{block_number: nil} = reward) do
    %{
      amount: reward.amount,
      account:
        Helper.address_with_info(
          reward.account_address,
          reward.account_address_hash
        ),
      associated_account:
        Helper.address_with_info(
          reward.associated_account_address,
          reward.associated_account_address_hash
        )
    }
  end

  def prepare_election_reward(%ElectionReward{} = reward) do
    %{
      amount: reward.amount,
      block_number: reward.block_number,
      block_hash: reward.block_hash,
      epoch_number: reward.block_number |> CeloHelper.block_number_to_epoch_number(),
      account:
        Helper.address_with_info(
          reward.account_address,
          reward.account_address_hash
        ),
      associated_account:
        Helper.address_with_info(
          reward.associated_account_address,
          reward.associated_account_address_hash
        ),
      type: reward.type
    }
  end

  defp burn_fraction_decimal(burn_fraction_fixidity_lib)
       when is_integer(burn_fraction_fixidity_lib) do
    base = Decimal.new(1, 10, 24)
    fraction = Decimal.new(1, burn_fraction_fixidity_lib, 0)
    Decimal.div(fraction, base)
  end

  defp fee_handler_base_fee_breakdown(base_fee, block_number) do
    with {:ok, fee_handler_contract_address_hash} <-
           CeloCoreContracts.get_address(:fee_handler, block_number),
         {:ok, %{"address" => fee_beneficiary_address_hash}} <-
           CeloCoreContracts.get_event(:fee_handler, :fee_beneficiary_set, block_number),
         {:ok, %{"value" => burn_fraction_fixidity_lib}} <-
           CeloCoreContracts.get_event(:fee_handler, :burn_fraction_set, block_number) do
      burn_fraction = burn_fraction_decimal(burn_fraction_fixidity_lib)

      burnt_amount = Decimal.mult(base_fee, burn_fraction)
      burnt_percentage = Decimal.mult(burn_fraction, 100)

      carbon_offsetting_amount = Decimal.sub(base_fee, burnt_amount)
      carbon_offsetting_percentage = Decimal.sub(100, burnt_percentage)

      celo_burn_address_hash_string = CeloHelper.burn_address_hash_string()

      address_hashes_to_fetch_from_db = [
        fee_handler_contract_address_hash,
        fee_beneficiary_address_hash,
        celo_burn_address_hash_string
      ]

      address_hash_string_to_address =
        address_hashes_to_fetch_from_db
        |> Enum.map(&(&1 |> Chain.string_to_address_hash() |> elem(1)))
        |> Chain.hashes_to_addresses(@address_params)
        |> Map.new(fn address ->
          {
            to_string(address.hash),
            address
          }
        end)

      %{
        ^fee_handler_contract_address_hash => fee_handler_contract_address_info,
        ^fee_beneficiary_address_hash => fee_beneficiary_address_info,
        ^celo_burn_address_hash_string => burn_address_info
      } =
        Map.new(
          address_hashes_to_fetch_from_db,
          &{
            &1,
            Helper.address_with_info(
              Map.get(address_hash_string_to_address, &1),
              &1
            )
          }
        )

      %{
        recipient: fee_handler_contract_address_info,
        amount: base_fee,
        breakdown: [
          %{
            address: burn_address_info,
            amount: Decimal.to_float(burnt_amount),
            percentage: Decimal.to_float(burnt_percentage)
          },
          %{
            address: fee_beneficiary_address_info,
            amount: Decimal.to_float(carbon_offsetting_amount),
            percentage: Decimal.to_float(carbon_offsetting_percentage)
          }
        ]
      }
    else
      _ -> nil
    end
  end

  defp governance_base_fee_breakdown(base_fee, block_number) do
    with {:ok, address_hash_string} when not is_nil(address_hash_string) <-
           CeloCoreContracts.get_address(:governance, block_number),
         {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string) do
      address =
        address_hash
        |> Chain.hash_to_address(@address_params)
        |> case do
          {:ok, address} -> address
          {:error, :not_found} -> nil
        end

      address_with_info =
        Helper.address_with_info(
          address,
          address_hash
        )

      %{
        recipient: address_with_info,
        amount: base_fee,
        breakdown: []
      }
    else
      _ ->
        nil
    end
  end

  def extend_transaction_json_response(out_json, %Transaction{} = transaction) do
    token_json =
      case {
        Map.get(transaction, :gas_token_contract_address),
        Map.get(transaction, :gas_token)
      } do
        # todo: this clause is redundant, consider removing it
        {_, %NotLoaded{}} ->
          nil

        {nil, _} ->
          nil

        {gas_token_contract_address, gas_token} ->
          if is_nil(gas_token) do
            Logger.error(fn ->
              [
                "Transaction #{transaction.hash} has a ",
                "gas token contract address #{gas_token_contract_address} ",
                "but no associated token found in the database"
              ]
            end)
          end

          TokenView.render("token.json", %{
            token: gas_token,
            contract_address_hash: gas_token_contract_address
          })
      end

    Map.put(out_json, "celo", %{"gas_token" => token_json})
  end

  defp maybe_add_epoch_info(
         celo_epoch_json,
         block,
         true
       ) do
    epoch_rewards_json = render("celo_epoch_distributions.json", block)

    # Workaround: we assume that if epoch rewards are not fetched for a block,
    # we should not display aggregated election rewards for it.
    #
    # todo: consider checking pending block epoch operations to determine if
    # epoch is fetched or not
    aggregated_election_rewards_json =
      if epoch_rewards_json do
        render("celo_aggregated_election_rewards.json", block)
      else
        nil
      end

    celo_epoch_json
    |> Map.put("distributions", epoch_rewards_json)
    |> Map.put("aggregated_election_rewards", aggregated_election_rewards_json)
  end

  defp maybe_add_epoch_info(
         celo_epoch_json,
         _block,
         false
       ),
       do: celo_epoch_json

  defp maybe_add_base_fee_info(celo_json, block_or_transaction, true) do
    base_fee_breakdown_json = render("celo_base_fee.json", block_or_transaction)
    Map.put(celo_json, "base_fee", base_fee_breakdown_json)
  end

  defp maybe_add_base_fee_info(celo_json, _block_or_transaction, false),
    do: celo_json

  def extend_block_json_response(out_json, %Block{} = block, single_block?) do
    celo_epoch_json =
      %{
        "is_epoch_block" => CeloHelper.epoch_block_number?(block.number),
        "number" => CeloHelper.block_number_to_epoch_number(block.number)
      }
      |> maybe_add_epoch_info(block, single_block?)

    celo_json =
      %{"epoch" => celo_epoch_json}
      |> maybe_add_base_fee_info(block, single_block?)

    Map.put(out_json, "celo", celo_json)
  end
end
