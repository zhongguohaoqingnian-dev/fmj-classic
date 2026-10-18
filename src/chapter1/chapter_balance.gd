extends RefCounted
## Remake playability rules. Story scripts and source data remain intact.
const VERSION := 1
const BOSS_HP := {"3:3:5":2000,"3:3:18":3200,"3:3:37":1800,"3:3:38":2800,
 "3:3:39":5000,"3:3:40":4200,"3:3:41":4600,"3:3:42":5000,"3:3:43":5200,
 "3:3:44":6000,"3:3:45":6500,"3:3:46":6500,"3:3:47":9000}
static func enemy(source:Dictionary) -> Dictionary:
 var out:=source.duplicate(true)
 if BOSS_HP.has(str(out.id)):
  out.hp=mini(int(out.hp),int(BOSS_HP[out.id]))
  out.max_hp=mini(int(out.max_hp),int(BOSS_HP[out.id]))
 if int(source.max_hp)>=3000:
  out.mp=mini(int(out.mp),360)
  out.max_mp=mini(int(out.max_mp),360)
 out.reward_exp=int(out.get("reward_exp",0))*2
 return out
static func buy_price(goods:Dictionary) -> int:
 var price:=int(goods.get("buy_price",0))
 if int(goods.get("type",0)) not in [9,10] or price<=0:return price
 var adjusted:=maxi(1,int(ceil(price*0.4)))
 if int(goods.get("type",0))==9:
  var recovery:=int(goods.get("hp_effect",0))*0.5+int(goods.get("mp_effect",0))*0.8
  if recovery>0:adjusted=mini(adjusted,int(20+recovery))
 return adjusted
static func sell_price(goods:Dictionary) -> int:
 var price:=int(goods.get("sell_price",0))
 return mini(price,int(buy_price(goods)/2)) if int(goods.get("type",0)) in [9,10] and int(goods.get("buy_price",0))>0 else price
