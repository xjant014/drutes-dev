module schwarz_dd2subcyc
    use typy
    public :: schwarz_subcyc
    private :: build_xvect
    private :: domains_solved
    private :: results_extractor
    private :: locmat_assembler
    private :: search_error_cluster
    
    real(kind=rkind), dimension(:), allocatable, private, save :: resvct, corrvct
 
    contains

      !>solves the problem using Picard method with Schwarz multiplicative domain decomposition reflecting the nonlinear problem
      subroutine schwarz_subcyc(ierr, itcount, success)
	use typy
	use globals
	use global_objs
	use pde_objs
	use feminittools
	use fem_tools
	use linAlg
	use debug_tools
	use sparsematrix
	use decomp_vars
	use decomp_tools
	use decomposer
	use postpro
        use femmat
        use core_tools
        use simplelinalg
        use printtools
        use debug_tools

	integer, intent(out) :: ierr
	integer(kind=ikind), intent(out) :: itcount
	integer(kind=ikind) ::  fin, pcg_it, subfin
	logical, intent(out) :: success
	integer(kind=ikind) :: i, proc,j, m, l, k, ii, nd
	real(kind=rkind) :: error, loc_error, res_error, reps, cumerr
	real(kind=rkind), dimension(:), allocatable, save :: coarse2fine
	logical :: dt_fine, first_run, picard_done, reset_domains
	integer :: ierr_loc
	integer(kind=ikind), dimension(:), allocatable :: radek, radek2, radek3
	character(len=128) :: text
	real(4), dimension(2,2) :: taaray
	real(4), dimension(2) :: rslt
	real(kind=rkind) :: val


        call etime(taaray(1,:), rslt(1))
	proc = ubound(pde,1)
	fin = maxval(pde(proc)%permut(:))
	itcount = 0
	inner_criterion = 1e-4

	!reset local-local cluster iteration count
        ddcoarse_mesh(:)%iter_count = 4
	
	!the residual vector is not allocated, thus we are at the beginning
	if (.not. allocated(resvct)) then
          first_run = .true.
	  allocate(resvct(fin))
	  allocate(corrvct(fin))          
          call set_subdomains()
        else
          first_run = .false.
        end if

        subdomain(:)%time_step = time_step
        
        subdomain(:)%time = time
        
        subdomain(1)%time_step = time_step/10.0
              
                
        !reset local subdomain iteration count
        subdomain(:)%itcount = 0                

        !reset successes on domains
        subdomain(:)%solved = .false.
   	
	picard_done = .false.
	

        write(unit=terminal, fmt="(a)") "  "
        write(unit=terminal, fmt="(a, I4,a)") " Solving", ubound(subdomain,1),  " subdomains .... "
        

	picard_loop: do
	
          itcount = itcount + 1
	  
	  cumerr = 0
	  
	  subdoms:  do i=1, ubound(subdomain,1)
	  
	    subfin = subdomain(i)%ndof
	


! 	    if (res_error > inner_criterion) then
! 	      subdomain(i)%solved = .false.
! 	    else
! 	      subdomain(i)%solved = .true.
! 	    end if
	    
	    if (.not. subdomain(i)%solved) then
	       
	      call solve_subdomain(subdomain(i), reps=1e-20)

	      call search_error_cluster(subdomain(i), itcount) 
	      
	      subdomain(i)%xvect(:,2) = subdomain(i)%xvect(:,3)

	      subdomain(i)%itcount = itcount
	      
	      
	      if (abs(subdomain(i)%time - time - time_step) < 10*epsilon(time) ) then 
		subdomain(i)%solved = .true.
	      else
		if (norm2(corrvct(1:subfin)) < iter_criterion) then
		  subdomain(i)%time  = subdomain(i)%time + subdomain(i)%time_step
		  subdomain(i)%xvect(1,:) =  subdomain(i)%xvect(2,:)
		  print *, "solved subdom:", i
		end if
		  
	      end if
	      
	      	                  ! check local residual
	      res_error = norm2(subdomain(i)%resvct%main)
	      
	      call combinevals(subdomain(i))
	      
	      val=subdomain(1)%xvect(subdomain(1)%invpermut(11),2)
	      
	      print *, i, "time:", subdomain(i)%time, norm2(corrvct(1:subfin)), subdomain(i)%solved, val
	      
	      call wait()
	      
	    end if
	       
	  end do subdoms
	  
  	    
  	  call build_xvect()
  
  	    
	  call progressbar( int(100*ndofs_solved()/(1.0*ddinfo%ndofs_tot)))
	  

	  if (domains_solved() == ubound(subdomain,1)) then
	    call etime(taaray(2,:), rslt(2))
	    do i=1, ubound(subdomain,1)
	      if (.not. subdomain(i)%critical .and. subdomain(i)%itcount>1 ) then
		reset_domains = .true.
		EXIT
	      else
		reset_domains = .false.
	      end if
	    end do
	   
	    call printtime("Time spent on iterations: ", rslt(2)-rslt(1))
	    
	    if (reset_domains) then
	      call build_xvect()
	      call set_subdomains()
	    end if
	    
	    
	    success = .TRUE.
	    ierr = 0
	    write(unit=file_ddinfo, fmt=*) time, itcount, "|", subdomain(:)%ndof
	    call flush(file_ddinfo)
	    EXIT picard_loop
	  end if

	  if (itcount > max_itcount) then
	    call set_subdomains()
	    success = .FALSE.
	    ierr = 1
	    RETURN
	  end if

        end do picard_loop



        do proc=1, ubound(pde,1)
	  do i=1, ubound(subdomain,1)
	    dt_fine = pde(proc)%dt_check()
	  end do
        end do
        
        if (.not.(dt_fine)) then
          ierr = 2
          success = .false.
          RETURN
        else
          ierr = 0
          call results_extractor()
          do i=1, ubound(subdomain,1)
	    subdomain(i)%xvect(:,1) = subdomain(i)%xvect(:,3)
	  end do
        end if

      end subroutine schwarz_subcyc
      
      subroutine solve_subdomain(sub, reps)
	use typy
	use decomp_vars
	use decomp_tools
	use sparsematrix
	use simplelinalg
	use pde_objs
	
	class(subdomain_str), intent(in out) :: sub
	real(kind=rkind), intent(in) :: reps
	
	integer(kind=ikind) :: subfin
	real(kind=rkind) :: error
	integer :: ierr

      
	call locmat_assembler(mtx=sub%matrix, bvect=sub%bvect, &
	       permut=sub%permut, dt=sub%time_step, invpermut=sub%invpermut, ierr=ierr)


	call locmat_assembler(mtx=sub%extmatrix, bvect=sub%extbvect, &
	       permut=sub%extpermut, dt=sub%time_step, invpermut=sub%extinvpermut, ierr=ierr)
	 
	call getres_loc(sub)
	
        resvct = 0
        
        subfin = sub%ndof
	      
	resvct(sub%permut(1:sub%ndof)) = sub%resvct%main
	      
	resvct(sub%extpermut(1:sub%extndof)) = sub%resvct%ext
	
        corrvct(1:subfin) = 0.0
        
        call diag_precond(a=sub%matrix, prmt=sub%permut,  mode=1)
 	                    
	call solve_matrix(sub%matrix, resvct, corrvct(1:subfin), ilev1=0, itmax1=subfin, reps1=reps)
 	      
	call diag_precond(a=sub%matrix, x=corrvct(1:subfin), mode=-1)
 	     	      
	error = maxval(abs(corrvct(1:subfin)))
	
	sub%xvect(:,3) = sub%xvect(:,2) + corrvct(1:subfin)

      
      end subroutine solve_subdomain
      
      subroutine build_xvect()
	use typy
	use globals
	use global_objs
	use pde_objs
	use decomp_vars
	use debug_tools
	
	integer(kind=ikind) :: i, glob, loc, subcrit


!         pde_common%xvect(:,2) = 0.0_rkind
        
        
!         do i = 1, ubound(subdomain,1)
! 	  do loc = 1, subdomain(i)%ndof
! 	    glob =  subdomain(i)%permut(loc)
! 	    pde_common%xvect(glob,2) = pde_common%xvect(glob,2) + subdomain(i)%returnval(loc,time+time_step)*prolong_mtx%get(glob,i)
! 	  end do
! 	end do

	do i = 1, ubound(subdomain,1)
	  do loc = 1, subdomain(i)%ndof
	    glob =  subdomain(i)%permut(loc)
	    pde_common%xvect(glob,1:3) = subdomain(i)%xvect(loc,1:3)
	  end do
	end do

!         pde_common%xvect(:,3) = pde_common%xvect(:,2)
        
!         pde_common%xvect = 0

      end subroutine build_xvect
      
      subroutine combinevals(subdom)
	use typy
	use decomp_vars
	use pde_objs
	use debug_tools
	
	
	type(subdomain_str), intent(in out) :: subdom
	integer(kind=ikind) :: i, glob, globgeom, j, sub, loc
	real(kind=rkind) :: value
	
	do i=1, ubound(subdom%xvect,1)
	  glob = subdom%permut(i)
	  globgeom = pde_common%invpermut(glob)
	  if (ddinfo%nodesinsub(globgeom)%pos > 1) then
	    value = 0
	    do j=1, ddinfo%nodesinsub(globgeom)%pos
	      sub = ddinfo%nodesinsub(globgeom)%data(j)
	      loc = subdomain(sub)%invpermut(glob)
	      value = value + subdomain(sub)%returnval(loc, subdom%time)*prolong_mtx%get(glob,sub)
	    end do
! 	    	      print *, value
! 	      call wait()
	    subdom%xvect(i, 2:3) = value
	  end if
	end do
	
      
      end subroutine combinevals

      subroutine search_error_cluster(sub, itcount)
	use typy
	use globals
	use global_objs
	use decomp_vars
	use debug_tools
	use pde_objs

	type(subdomain_str), intent(in) :: sub
	integer(kind=ikind), intent(in) :: itcount

	integer(kind=ikind) :: i, j, ii, jj, el, nd, xpos, xpos_loc
	real(kind=rkind) :: loc_error
	

	do i=1, ubound(sub%coarse_el,1)
	  j = sub%coarse_el(i)
	  loc_error = 0
	  do ii=1, ubound(ddcoarse_mesh(j)%elements,1)
	    el = ddcoarse_mesh(j)%elements(ii)
	    do jj = 1, ubound(elements%data,2)
	      nd = elements%data(el,jj)
	      xpos = pde(1)%permut(nd)
	      if (xpos > 0) then
		xpos_loc = sub%invpermut(xpos)
		loc_error = max(loc_error, abs(sub%xvect(xpos_loc,3)-sub%xvect(xpos_loc,2)) )
	      end if
	    end do
	  end do
	  if (loc_error > iter_criterion) then
	    ddcoarse_mesh(j)%iter_count = ddcoarse_mesh(j)%iter_count + 1
	  end if
	end do
  

      end subroutine search_error_cluster


      subroutine results_extractor()
	  use typy
	  use globals
	  use global_objs
	  use debug_tools
	  use pde_objs

	  integer(kind=ikind) :: i, j, proc


	  do proc=1, ubound(pde,1)
	      do i=1, nodes%kolik
		  if (pde(proc)%permut(i) > 0) then
		      pde(proc)%solution(i) = pde_common%xvect(pde(proc)%permut(i),3)
		  else
		      j = nodes%edge(i)
		      pde(proc)%solution(i) = pde(proc)%bc(j)%value
		  end if
	      end do
	  end do


	  pde_common%xvect(:,1) = pde_common%xvect(:,3)
	  pde_common%xvect(:,2) = pde_common%xvect(:,3)

      end subroutine results_extractor
 

      !> counts number of solved subdomains
      function domains_solved() result(no)
        use typy
        use globals
        use global_objs
        use decomp_vars
        
        integer(kind=ikind) :: no

        integer(kind=ikind) :: i

        no = 0

        do i=1, ubound(subdomain,1)
          if (subdomain(i)%solved) then
            no = no + 1
          end if
        end do

      end function domains_solved
      
            !> counts number of solved subdomains
      function ndofs_solved() result(no)
        use typy
        use globals
        use global_objs
        use decomp_vars
        
        integer(kind=ikind) :: no

        integer(kind=ikind) :: i

        no = 0

        do i=1, ubound(subdomain,1)
          if (subdomain(i)%solved) then
            no = no + subdomain(i)%ndof
          end if
        end do

      end function ndofs_solved
      
    
   subroutine locmat_assembler(mtx, bvect, permut,  dt, invpermut, ierr)
      use typy
      use globals
      use global_objs
      use pde_objs
      use capmat
      use stiffmat
      use feminittools
      use geom_tools
      use fem_tools
      use re_constitutive
      use linAlg
      use solver_interfaces
      use debug_tools     
      use decomp_vars
      
      class(extsmtx), intent(in out) :: mtx
      real(kind=rkind), dimension(:), intent(out) :: bvect
      integer(kind=ikind), dimension(:), intent(in) :: permut
      real(kind=rkind), intent(in) :: dt
      integer(kind=ikind), dimension(:), intent(in) :: invpermut
      integer, intent(out) :: ierr
      integer(kind=ikind) :: el,j,k,l, proc, ll, limits, nd, ii, pnd, jaj, joj
      logical, dimension(:), allocatable, save :: elsolved
      type(integpnt_str) :: quadpnt
      real(kind=rkind) :: value

      
      if (.not. allocated(elsolved)) then
        allocate(elsolved(elements%kolik))
      end if
      
      
      call null_problem(mtx, bvect)

      
      elsolved = .false. 
      
!       limits = ubound(stiff_mat,1)/ubound(pde,1)
      
      proc = 1

      loop_nodes: do pnd=1, ubound(permut,1)

                      if (permut(pnd) == 0) then
                        EXIT loop_nodes
                      end if

                      nd = permut(pnd)

                      nd = pde_common%invpermut(nd)


                      do ii=1,nodes%el2integ(nd)%pos

                        el = nodes%el2integ(nd)%data(ii)

                        if (.not. elsolved(el)) then

                          quadpnt%type_pnt = "ndpt"
                          quadpnt%column = 1                      
                          do k = 1, ubound(elements%data,2)                           
                            quadpnt%order = elements%data(el,k)
                            elnode_prev(k) = pde(1)%getval(quadpnt)
                          end do  

                          
                          
                          call build_bvect(el, dt)

                          call build_stiff_np(el, dt)

                          call pde_common%time_integ(el)

                          stiff_mat = stiff_mat + cap_mat

                          call in2global(el,mtx, bvect, invpermut)
                          
                          elsolved(el) = .true.
                        end if
                      end do
      end do loop_nodes

    end subroutine locmat_assembler


end module schwarz_dd2subcyc
